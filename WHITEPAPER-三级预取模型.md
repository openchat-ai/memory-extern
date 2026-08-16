# 预测驱动的三级专家缓存调度白皮书（草稿）

> 2026 · 基于 SparkMoE 与 anemll/flash-moE 源码与设计文档的反向工程综合
> 核心论断：MoE 推理的瓶颈不是计算，是"专家权重的搬运调度"。
> 两大开源工程已收敛到同一个抽象——**slot（帧）**；它们的分野只在**预取/预测层**，这正是可以超车的缝隙。

---

## 0. TL;DR

| 工程 | 存储抽象 | 命中策略 | 预取/预测 | 上限模式 |
|------|----------|----------|-----------|----------|
| llama.cpp 主线 | mmap 全量驻留 | 内核缺页 | 无 | 无 |
| SparkMoE | RAM slot 池 + LRU | 读盘即 miss | **无** | 无 |
| anemll Flash-MoE | GPU/RAM slot-bank + SSD sidecar | 流式安装 | **temporal 预取 + oracle** | oracle-all-hit |

**结论**：slot 分页已是既定事实标准；下一个增量是"预测层"。本白皮书提出在两者之上叠加
**静态热表 + 时序预取 + 双缓冲** 的三级调度模型，目标：CPU 上 decode 提速 20~50%（经验估计）。

---

## 1. 问题定义

MoE 模型：`L` 层 × `E` 个专家/层，每 token 激活 `K` 个（如 Qwen3.6: L=48, E=64/128, K=4/8）。

- 权重总量 ~数十 GB（SSD），驻留内存只有 ~若干 GB 预算。
- decode 时每个 token 都要访问 `L×K` 个专家，专家分布高度偏斜（幂律）且强时序相关。
- 关键矛盾：**I/O 延迟（5~20ms/次磁盘读）vs 计算时间（<2ms/token）**。缓存 miss 直接卡死流水线。

数据形态（GGUF 内专家张量布局）：
```
ffn_gate_exps.weight  [n_ff, n_embd, E]   ← 第 3 维是专家，nb[2]=专家步长（字节）
ffn_up_exps.weight    [n_ff, n_embd, E]
ffn_down_exps.weight  [n_embd, n_ff, E]
```

---

## 2. 反向后获得的三个成熟机制

### 2.1 slot 分页（SparkMoE `src/moe-paging/`，~1250 行，已逐行核验）

- 每层预分配 `S_l` 帧（slot）；`layer_cache` 构造时建 `entries[]`/`expert_to_slot[]`/`pin_requested[]`（`moe-cache.cpp:13-37`）。
- 帧内存 = `bind_pool` 分配的 GGML 张量，`ne[2]=n_slots` 且**硬校验 `nb[2] == GGUF 专家步长`**（`moe-cache.cpp:58-63`），`pread` 按专家切片直接覆盖帧内存——与 GGML 视图零拷贝对齐。
- 状态机：`empty → loading → ready → error`（`in_use` 枚举存在，但实际由 `active_refs` 计数承担，`moe-cache.h:21-37`）。
- 调度 `resolve()`（`moe-cache.cpp:96-228`）：
  1. 加锁（`try_lock` 失败记 `waits`）→ 去重（重复路由记 `duplicate_requests`）→ 越界/超槽校验；
  2. 命中：`expert_to_slot[]` → `last_use=++clock`、`active_refs++`；
  3. miss：`choose_victim`（跳过 reserved/pinned/`active_refs≠0`/loading，`moe-cache.cpp:77-94`）→ 逐出并翻转 `expert_to_slot[old]` → 置 loading；
  4. I/O：每 miss 专家 × 每个张量家族各提交一个 `pread` 到 io 线程池（`moe-cache.cpp:171-186`）→ **同步 `future.get()` 全部等齐**（`187-196`）——零预取、同步屏障；
  5. 任一读失败 → 事务回滚（条目置 error、`expert_to_slot` 复位，`198-207`）；全部成功 → 置 ready 提交（`209-213`）；
  6. 输出 slot_ids，递减 `active_refs`。
- 预算：`S_l = clamp(cache_bytes/层数/单专家字节, minimum_slots, E)`（`moe-paging.cpp:42-68`）；`max_safe_ubatch = min_l(S_l)/K`（`moe-paging.cpp:109-124`）。
- 图集成（`llama-graph.cpp:1986-2015`）：`bind_pool` 换源张量 → `ggml_cont` → `remap_ids`（`ggml_map_custom1`，thread 0 内执行 resolve）把专家 ID 翻成 slot ID；`mul_mat_id` 用 slot ID 索引第 3 维，lora/bias 仍走原始 expert ID——**调度层与计算层只隔一个"第 3 维索引"契约**。
- **现成钩子（关键发现）**：`set_expert_pinned`/`set_pinned`（`moe-paging.cpp:102-107`、`moe-cache.cpp:230-241`）可把专家置 pinned（`choose_victim` 永不逐出；未加载的热专家加载时自动置 pinned），但**当前零调用方**——静态热表（L0 档）只差一行接线，`resolve()` 零改动。
- 指标已内建：`stats` 快照含 hits/misses/bytes_read/read_count/read_latency_us/evictions/waits/duplicate_requests（`moe-paging.cpp:162-177`），其中 `waits` 即 §5 的锁竞争指标。
- **软肋**：零预取；`read_exact` 的 timeout 是读后检查、非可中断超时（`moe-io-posix.cpp:60-63`）；`generation` 字段只增未用，像是给未来异步失效预留。

### 2.2 时序预取 + oracle（anemll Flash-MoE）

- slot-bank 概念相同（每层 slot 归属、SSD 侧车文件 `--moe-sidecar` 专家主序布局）。
- 新增 `--moe-prefetch-temporal`：**运行时一步时序预取**——用当前 token 的路由结果预取下一 token 的专家。
- `oracle replay`：把真实 trace 重放，测量"全命中"上限（`oracle-all-hit`）与"一步预知"上限（`oracle one-step`），把运行时差距拆成"存储 miss 成本" vs "调度/计算成本"。
- **设计洞察**：oracle 模式不是玩具，是**性能预算分解工具**（见 §5）。

### 2.3 银行建模工作流（anemll `moe-bank-modeling-workflow.md`）

- 成本模型：`resident_bytes = Σ_layers (S_l × Σ bytes_per_expert(层内路由家族))`。
- 工作负载指标：`unique experts/layer`、`expert frequency`、`misses/token`、`bytes/token`、`full-hit layer-call rate`。
- 策略对比：`uniform per-layer static` vs `global static under byte budget` vs `refillable LRU`。
- 校准锚点：`baseline streamed / current banked / oracle all-hit / oracle one-step`。
- **可复现案例（Kimi-K2.5）**：60 路由层 × 384 专家，sidecar 232.58 GiB；bank 8 ≈ 4.51 GiB、bank 64 ≈ 36.10 GiB。

---

## 3. 提出的模型：三级预取调度器（3-Tier Prefetch Scheduler）

```
                    ┌─────────────────────────────────────────────┐
                    │                预测器（离线 + 在线）          │
                    │  offline: 路由 trace → 每层静态热表 H_l      │
                    │  online : n 步时序马尔可夫/ngram P(exp_t+1   │
                    │           | exp_t..exp_t-n+1)                │
                    └───────────────┬─────────────────────────────┘
                                    │ 预测的下一批专家集
   ┌─────────────── SSD (L2) ───────────────┐
   │  GGUF 专家切片 / sidecar（按索引 pread） │
   └───────────────▲───────────────▲────────┘
                   │ 预取读         │ miss 读
   ┌───────────────┴───────────────┴────────────────────────────┐
   │                RAM slot 池 (L1)                            │
   │  ┌─────────────┐  ┌─────────────┐  ┌──────────────────┐   │
   │  │ 计算池  A    │  │ 预取池  B    │  │ 静态热表（pinned）│   │
   │  │ LRU, 当前批 │  │ 下一批候选  │  │ 离线 top-N 常驻   │   │
   │  └─────────────┘  └─────────────┘  └──────────────────┘   │
   └────────────────────────────────────────────────────────────┘
                                    │ 计算与预取双缓冲重叠
   ┌────────────────────────────────▼───────────────────────────┐
   │ GGML 图：remap → mul_mat_id → 计算当前批 → 同时读下一批       │
   └────────────────────────────────────────────────────────────┘
```

### 3.1 分层职责

| 层 | 介质 | 内容 | 调度者 | 特征 |
|----|------|------|--------|------|
| L0 热表 | 常驻 pinned slot | 离线 trace 选出的 top-N 热专家/层 | 静态分配器 | 确定性，占 ~30-50% 预算 |
| L1 计算池 | RAM slot | 当前批实算专家，LRU+滞回 | 运行时 | 动态，占 ~40% 预算 |
| L1.5 预取池 | RAM slot | 下一批预测专家（双缓冲） | 时序预测器 | 与计算重叠 |
| L2 | SSD | 全部专家 | io_executor + pread | 仅冷 miss |

### 3.2 关键设计点

1. **双缓冲**：`resolve()` 当前批用计算池 A 时，预取器把 `P(下一批)` 装进预取池 B；下一 token 直接交换角色。**消除同步屏障**（SparkMoE 最大软肋）。
2. **静态热表 + 动态 LRU 混合**：热专家（幂律顶端，~20% 专家覆盖 ~70% 访问）永久 pinned 在 L0；冷专家走 L1 LRU；两级之间用"升级/降级"阈值（连续命中 n 次 → 升级；长期未用 → 降级回 L1）。带滞回，避免 moe-autopilot 指出的 thrash。**SparkMoE 已内建 pinned 机制**：`set_expert_pinned` 逐层置 pinned，`choose_victim` 永不逐出 pinned 槽——L0 档零改造成本。
3. **预算分配**：先按 `bytes/expert` 均匀兜底，再用 trace 的 `expert frequency` 做**全局字节预算下的加权分配**（对应 anemll 的 `global static under byte budget`），比 uniform 省 10-30% 内存或等内存多 10-30% 命中。
4. **预测器选型**：
   - 冷启动（前几十 token）：无预测，退化为纯 LRU。
   - 稳定段：一阶 Markov 按层维护 `E×K` 转移表（每层独立），成本 ~E²×L×2B 忽略不计。
   - 只在 `P(top candidate) > 0.5` 时才预取，否则浪费 I/O 带宽。
5. **IO 协同**：预取读与计算读共用 io_executor，但预取任务优先级低、可被取消（miss 读优先）。配合 `pread` 精准切专家，天然绕过 mmap 缺页同步。

### 3.3 复杂度代价（诚实清单）

- 需要**路由 trace** 才能生成热表与校准预测器（一次代价，可复用）。
- 双缓冲多占 ~30% slot 内存。
- 预测错误的代价 = 一次额外的磁盘读（可量化：`bytes/token × miss_rate`）。
- 多一个线程池 + 每层一张转移表，代码量估算 +600~1000 行（对齐 SparkMoE 的简洁风格）。

### 3.4 L0-SRAM（片上全局驻留层）：决策规则

SRAM 档位追问的是：如果片上有一小池快内存（50~200 MB，**全局共享**、非按层复制），值得把
一部分专家常年钉在里头吗？注意它与 §3.1 的 L0 热表不同——L0 是 RAM 里的按层 pinned 槽
（容量大、随预算伸缩）；SRAM 是**全局**小池，任何一层 miss 都能捞，代价是容量只有个位数到
几十个槽（K3 17.5 MiB/专家时 200 MB 仅 11 槽）。

**角色定位**：SRAM 是**流量过滤/驻留层，不是延迟隐藏层**。专家 miss 到 DRAM 是廉价路径
（相对 SSD），SRAM 的价值不在"躲过慢读"，而在"把 DRAM 侧重复流量挡掉"。这个定位决定了它
只有一个指标：**命中率**，而命中率由路由统计决定，与 I/O 调度/预取机制正交——延迟隐藏
（§5.6 的双缓冲）换不来命中率。

**决策变量（设计规则）**：
- **O —— 跨层热集重叠度**：同一批热专家是否在多层重复被选。O 高 → 全局静态核成立；O≈0 →
  各层热集不相交，全局池留谁都没用。
- **全局 n50** —— 按全局频次排序，覆盖 50% 请求需要的专家数（换算成 GB 与 SRAM 容量比）。

| O | 含义 | 决策 |
|---|------|------|
| 高（全局热集 ≈ 各层热集并集） | 静态核覆盖多数流量 | 静态 top-K 钉住——浪费驻留最小：热集稳定时 LRU 反而每 token 逐出又重载 |
| 中 | 热核 + 长尾 | 静态核 + LRU 尾（§3.2-2 的混合，缩小到片上） |
| ≈0 | 各层热集不相交 | **跳过 SRAM**——全局池无物可留，容量不如按层 DRAM 槽 |

**合成 trace 陷阱（早期实验教训）**：用 shift-rotation 合成路由（各层热集为同一幂律的旋转）
做全局池实验，得到每 token 平均 323.5 次跨层重复引用、唯一专家仅 157/480——该构造**天然让
"同 id 专家跨层热"成立，等于预设 O 高**，结构上不适合作全局池分析。O 与全局 n50 必须用真实
路由 trace 求（§5.7 的决策规则触发实验）。

---

## 4. 最小可行性实现路径（对照 SparkMoE 结构）

```
1. 离线工具 profile_trace.py     ← trace JSONL → 热表 hot_list.txt（L0 pinned 工件）+ 转移表
                                   + B/C/D 档位上限表（离线决策门）
2. C 档（静态热表）：仅加 CLI `--moe-pin-file`，启动时按 hot_list.txt 调
   `set_expert_pinned()`，resolve() 零改动——**已交付补丁** `sparkmoe-src/patches/c-tier-pin.patch`
   （懒加载，见 `sparkmoe-src/C-TIER-PIN.md`，~100 行含解析校验）
3. moe-prefetch.cpp/h            ← 新模块：预测器 + 预取池 + 双缓冲状态机（真正的增量）
4. moe-cache.cpp 改造            ← resolve() 拆成 current/miss/prefetch 三段
5. moe-io-*.cpp 改造             ← 增加优先级队列 + 取消
6. llama-graph.cpp               ← remap 处注入预取池视图切换（对齐 remap_ids 模式）
7. 基准验证（§5）
```

参考复用点（已核验的行号）：
- 图集成抄 `llama-graph.cpp:1986-2015` 的 bind_pool/remap_ids（`ggml_map_custom1`）。
- 状态机抄 `moe-cache.cpp:96-228` 的 resolve/choose_victim/expert_to_slot/clock。
- I/O 抄 `moe-io-posix.cpp:29-65` 的 `pread` + `moe-io-common.cpp` 的线程池。
- L0 钩子直接用 `moe-paging.cpp:102` `set_expert_pinned`。

---

## 5. 基准方法学（从 anemll 工作流借鉴，防自欺）

固定 `seed/temp/prompt/-n`，对比五档：

| 档位 | 配置 | 回答的问题 |
|------|------|-----------|
| A. 基线流式 | 无 bank（全 miss） | 磁盘墙多高 |
| B. 纯 LRU | SparkMoE 现状 | 单纯缓存能到哪 |
| C. LRU + 热表 | 本设计 L0+L1 | 静态覆盖贡献多少 |
| D. C + 时序预取 | 本设计完整版 | 预取贡献多少 |
| E. oracle all-hit | 全驻留上限 | 还能挤多少（上界） |

指标：`tok/s`、`misses/token`、`bytes/token`、`cache hit rate`、`waits`（锁竞争）、
`E/D` 比值 = 剩余优化空间；`D/B` 比值 = 预测层净收益。
每档跑 30 分钟以上长 trace（anemll 建议 1h），短跑只会得到波动噪音。

### 5.5 Kimi-K2.5 规模化案例（离线估算）

**设定**（几何取自 anemll 存档，`moe-bank-modeling-workflow.md:153-171`）：
60 路由层 × 384 专家，原生 topk 8（anemll 实测降到 topk 4），sidecar 232.58 GiB →
10.34 MiB/专家；预算按 anemll bank 档（bank 8 = 4.51 GiB ≈ 7 槽/层）。路由为合成负载
（幂律 α=1.3，时序保持 stay=0.8，1000 token，`tools/profile_trace.py` 流式档位仿真）。

**银行档位扫描**（B 档 = 纯 LRU 仿真）：

| bank (GiB) | 槽/层 | uniform 静态 | global 贪心 | LRU 命中 | misses/token | bytes/token |
|------------|-------|--------------|-------------|----------|--------------|-------------|
| 4.51 | 7 | 0.46 | 0.47 | 0.139 | 413 | 4.27 GiB |
| 9.03 | 14 | 0.60 | 0.61 | 0.540 | 221 | 2.23 GiB |
| 18.05 | 28 | 0.73 | 0.73 | 0.679 | 154 | 1.56 GiB |
| 36.10 | 56 | 0.83 | 0.83 | 0.790 | 101 | 1.02 GiB |

**档位上限**（bank 4.51 GiB，4.51/9.03 两档一致的模式；全仿真见 trace-demo 报告）：

| 场景 | B 纯 LRU | C 热表+LRU | D 热表+时序(上界) | C/B | D/B |
|------|----------|-----------|-------------------|-----|-----|
| topk 8, stay 0.8 | 0.139 | 0.472 | 0.610 | **3.40x** | **4.40x** |
| topk 4, stay 0.8 | 0.576 | 0.592 | 0.715 | 1.03x | 1.24x |
| topk 8, stay 0.5 | 0.126 | 0.467 | 0.574 | **3.70x** | **4.55x** |

**发现（离线估计，待真实 trace 确认）**：

1. **原生 topk 8 + 小 bank 是纯 LRU 的坟场**：4.51 GiB 只有 7 槽/层，一个批次就需 8 个唯一
   专家，池子连一批都放不下，LRU 命中率跌到 14%，bytes/token 高达 4.27 GiB。
2. **静态热表是主导修复（3.4~3.7x），且近乎免费**：把 global-greedy 选出每层 ~7 个热专家
   pinned（`set_expert_pinned` 已内建、零调用方），命中率拉回 47%。决策门 §7-3 强烈通过。
3. **时序预取在 C 之上再加 ~30-40%**（D=0.61 vs C=0.47）；弱时序（stay 0.5）下 C 依旧 3.7x，
   因为 C 不依赖时序——**C 是先决条件，D 是锦上添花**。
4. **topk 4 时收益压缩**：7 槽≈1.75 批，LRU 本就能扛，C 只剩 3%，D 仍有 +24%——预取的价值
   在"池子小"的场景才最大。
5. 满命中层率在 4.51 GiB 下≈0（topk 8 > 7 槽），说明小预算下"整批命中"是奢望，**预取与命中
   必须以专家粒度计，不能以层级计**。

> 局限（诚实）：合成路由假设各层热集为同一幂律的旋转（shift-rotation），真实各层分布有差异；
> D 为"预取时序无损"上界；数值需用 `TRACE-COLLECTION.md` 钩子在真机上替换后重跑。

### 5.6 D 档双缓冲时序仿真（`tools/sim_scheduler.py`）

§5.5 的档位表只回答"容量下读多少"，不回答"预取是否来得及"。`sim_scheduler.py` 补上 I/O
时序：**同一套容量/LRU** 上对比 B（每层同步读，付 r0/层）与 D（token 末尾跨层合并一批
预取、只付一次 r0），共享 **FIFO 单链路**（`max(提交, 链路空闲) + r0 + 字节/BW`），预取与
同步补读公平排队。设备模型：单 NVMe，r0=5ms，带宽 2 GiB/s。

**小型模型 48×64 topk4，5 MiB/专家，compute 1.5 ms/token（trace-demo，2000 token）**：

| 预算 | 槽/层 | B 同步 LRU | D oracle k=1 | D k=2 | D k=4 | D/B (k=1) |
|------|-------|-----------|--------------|-------|-------|-----------|
| 4 GiB | 17 | 5.1 tok/s (197 ms/t) | 12.9 (77.6) | 11.9 | 9.8 | **2.5x** |
| 8 GiB | 34 | 11.5 (87.3) | 30.4 (32.9) | 29.9 | 28.4 | **2.6x** |

**K2.5 60×384 topk8，compute 2 ms/token（合成负载 1000 token）**：

| 预算/精度 | B | D oracle k=1 | D k=2 | D/B |
|-----------|-----|--------------|-------|-----|
| 4.51 GiB, Q8 (10.34 MiB/exp) | 0.42 tok/s | 0.45 | 0.27 | 1.07x |
| 9.03 GiB, Q4 (5.17 MiB/exp) | 1.46 | 2.34 | 2.08 | **1.6x** |

**最小超前量公式**（决定"能否打到 compute-bound"）：

```
k_min = ceil((r0 + 稳定态读 bytes/token / BW) / compute_per_token)
        · 小模型 @8GiB：I/O = 5ms + 60.5 MiB/2.048 = 34.5ms，compute 1.5ms → k_min = 24
        · 小模型 @4GiB：I/O = 75.9ms → k_min = 51
        · K2.5 @4.51GiB：I/O = 1419.9ms → k_min = 710（不可行）
```

**发现（时序层，此前档位表缺失的关键事实）**：

1. **单链路下 D 的吞吐上限 = 1/(r0 + bytes/token/BW)，与 lookahead 无关**。预取只隐藏
   延迟、不增加带宽；链路饱和后 k 再大也无效，反而因预取池挤占 LRU 逐出当前批（k 越大
   thrash 越重，实测 k=4 反而比 k=1 慢 ~10%）。**k_min 是悬崖条件**：达得到就跳到
   compute-bound（小模型 8 GiB：30.4 → 666 tok/s），达不到就锁死在带宽底。
2. **K2.5 原生 Q8 在任何调度下都是带宽墙**：连 D 都要 ~2.9 GiB/token，单 NVMe 只能到
   ~0.45 tok/s。**此场景该做的不是调度，而是把专家足迹砍半（Q4，D/B 1.6x）或上多盘并行 IO**。
3. **D 的真实收益 = r0 摊销**：B 每层调用同步付一次 r0（60 层/批），D 每 token 合并一批
   只付一次——这就是 2.5~2.6x 的主要来源（读字节数几乎相同），符合"消除同步屏障"的设计动机。
4. **lookahead 需要对应容量的预取池**：compute-bound 需要 `k_min × bytes/token` 的在途池，
   小模型 8 GiB 要 24×60.5 MiB ≈ 1.4 GiB 额外缓冲——预算分配必须显式建模 L1.5，否则
   k 增大只带来 thrash。
5. **一阶 top-1 马尔可夫预测器零贡献**：trace-demo transitions 实测 markov k=1 预取字节
   ≈0（预测专家几乎总已驻留），行为退化为 B（tok/s 与 B 相同）。预取必须用**下一批整体
   集合**（oracle/时序一步），不能逐专家 top-1。

> 局限：单链路 FIFO 未建模多盘并发/io_uring 深度；真实 NVMe 读带宽可能更高，但结论
> "单盘带宽是上限、lookahead 是悬崖条件"不变。

### 5.7 真实 trace 校准：SRAM 决策规则在 kimi-k3 上触发

真实路由 trace 来自 kimi-k3-in-c 的 `--dump-cache-trace`（92 路由层 × 896 专家/层，
**专家为每层独立权重**，10 万请求覆盖 68 个批次的 736 个 layer-run）。用 `tools/sram_stats.py`
重放。批结构：每个 run = 一个 (super-iter, layer) 组，5~12 个批 token 共享该层专家。

**决策变量实测**：

| 决策变量 | 实测 | 结论 |
|---------|------|------|
| 全局 n50 | 2337 keys = **41.01 GB** | 静态核 50% 覆盖需 41 GB ≫ SRAM → 否决 |
| O = global n50 / (92 × per-layer n50) | 0.929（per-layer n50 均值 27.3 专家 = 0.48 GB） | 各层热集近乎不相交 → **O≈0** |
| 批内复用 | 88.3% 请求为 intra-run 重复；跨 run 净复用仅 ~1.7% | 复用是"一层热专家服务一批 token"，批局部 |
| 批复用因子 | 86.7 不同专家 / 136 请求 = 1.57x | 命中率上限 = 1 − 1/1.57 = 36.3% |

**SRAM 档位实测**（静态全局 top-K vs 全局 LRU）：

| SRAM | 槽 | 静态 top-K | 全局 LRU |
|------|-----|-----------|---------|
| 50 MB | 2 | 0.14% | 0.09% |
| 100 MB | 5 | 0.33% | 0.60% |
| 200 MB | 11 | 0.70% | 4.50% |
| 400 MB | 23 | 1.36% | 27.87% |
| 800 MB | 47 | 2.56% | 34.79% |

**决策规则触发：O≈0 → 跳过 SRAM。** 两个结构性原因，都不是调度能补的：

1. 专家是每层独立权重（92×896），**全局池没有跨层可共享的权重**，"留热专家"无物可留；
2. 复用几乎全部批内局部（每 run ~87 个不同专家），只有足够大的**每层** DRAM 缓存能吃到
   它——LRU 命中率上限 36.3% 与 kimi-k3 仓库真机实测 "LRU 在 8~64 GB 恒为 36.24%"
   精确吻合（更大容量没有跨批复用可买），从实测侧印证 §5.6-1 的"墙上限是结构性的"。

**对白皮书的修正**：§3.4 的 SRAM 论证针对**共享专家**架构（跨层同 id 热，O 才有机会 >0）。
K3 这类 per-layer 架构下全局 SRAM 无意义——这不是缺陷，而是设计规则在真实数据上**正确触发
负分支**的用例：决策规则的 O 与全局 n50 输入必须来自真实路由 trace，合成 trace 会因构造
预设 O 高而假阳性（§3.4 陷阱）。计算内核优化（flat-row AVX2）与 SRAM 方向正交：被路由结构
否决的是 SRAM 本身，不是计算路径。

---

## 6. 已知边界与开放问题

- **预算不足 K**：slot 数 < K 时无解，只能降 `ubatch` 或降 `topk`（SparkMoE 已处理）。
- **专家间共享权重**：shared expert / dedup（anemll sidecar dedup 思路）当前未建模。
- **异构张量家族**：gate/up/down 步长不同，预算应按家族分账（anemll manifest 已给出字段）。
- **时序预测的适用性**：coding/agent 负载的路由熵更高，预测收益需要实测（`bytes/token` 会上升）。
- **KV cache 交互**：长上下文下 KV cache 抢占内存预算，slot 预算需与 KV 预算联合优化（见 llama-kv-cache 分节）。
- **SRAM 全局驻留层的适用架构**：真实 trace 已证实在 per-layer 专家架构（专家每层独立权重）下
  O≈0、全局 n50 达 41 GB，SRAM 档位应跳过（§5.7）；它只在**共享专家**架构下才有机会 >0，需要
  共享专家模型（如 K2.5 真 checkpoint）的真实 trace 才能判定。

---

## 7. 行动建议

1. 在 40GB 内存 i5 机器上跑 Qwen3.5/3.6 35B-A3B（UD-Q4_K_M ~20GB），用 SparkMoE `--moe-cache-mib` 扫 4/8/12/16 GiB 四档，先拿到 B 档基线。采集 trace 用 `sparkmoe-src/TRACE-COLLECTION.md` 的 remap_callback 钩子（研究补丁，勿合入主线）。
2. 用 anemll 的 trace + estimator 方法学（§5）生成热表和转移表——**这一步不写 C++，用 Python 即可**，产出即可发表为技术分析。现成实现：`tools/profile_trace.py`（输出 L0 热表工件 `hot_list.txt`、每层转移表、bank 命中率、B/C/D 档位上限与 C/B、D/B 净收益，直接构成第 3 条的决策门）。
3. C 档（静态热表）**不再是大工程**：核验发现 SparkMoE 已内建 pinned 钩子（`set_expert_pinned` 零调用方），实现成本约 50 行接线。且 §5.5 的 K2.5 规模离线案例显示：小 bank（7 槽/层）下 C/B = 3.4~3.7x，D/B = 4.4~4.6x——**决策门大幅通过，C 档应直接做**；D 档（双缓冲）在 C 档真机实测确认后投入。注意 §5.6 时序仿真修正了预期：D 的 tok/s 净增益为 2.5~2.6x（小模型）而非 4.4x（后者是命中率上界），且 K2.5 原生 Q8 场景是带宽墙、**先做 Q4/多盘 IO 再谈 D 档**。§5.7 进一步用真实 trace 判定：**SRAM 全局驻留层（L0-SRAM）在 per-layer 专家架构下应跳过**（O≈0、全局 n50=41 GB），C 档热表仍是 RAM 内按层 pinned 的正确做法。

> 终极认知差：这两个工程证明了"slot 分页"已经是最优解的下限，真正的上限由"预测器 + 双缓冲"决定。做第一个把"预测层"做成 CPU 默认路径的人。
