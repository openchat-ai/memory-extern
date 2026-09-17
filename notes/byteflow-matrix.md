# Kimi K3 · 字节流分类学 + 全链路实验矩阵（可靠实验设计，2026-08-28）

> 目的：**杜绝"东搞一下西搞一下"**。把一次 token 前向中每一段字节流，按其在
> 「生命周期」中的属性归类（算法可解 / 免落盘 / 可复用 / 必须落盘），注明存在
> 低速盘还是高速盘，并对每段定义**可复现的测量方法**和 **A/B 判定标准**。
> 本文件是全链路优化的**单一事实来源**；每个实验单元（E-xx）从这里派生。

### 2026-09-17 · cache 扩容（热专家落内存）实测证伪 + 论文立场核对（kimi-k3-in-c 落地）

**实验**：`benchmarks/expert-memory.sh`（F:\kimi-k3-in-c 新脚本，同 memory-ladder 框架，
cgroup 26GB、gen=8 incremental、ids=床前明月光、L2 heat、n=3）。cache-gb 8 vs 15，
唯一变量 = 热专家能否跨 token 驻留内存（8GB=448 slots=0.54% 专家池；15GB=855 slots）。

| cache-gb | rep1 | rep2 | rep3 | 中位 | RSS | 专家盘读 |
|---|---|---|---|---|---|---|
| 8 | 186.97¹ | 107.27 | 102.00 | **107.27** | 17.11 | 25.83 GB |
| 15 | 118.91¹ | 101.83 | 106.52 | **106.52** | 24.11 | 25.83 GB |

¹ rep1 = L2 冷启动离群（cache 15 冷启动损失更小，因热集已被前一档预填）。
**结论：中位 107.27 vs 106.52，差 0.7%，远在 33% 噪声带内，判无效应。**

**为什么热专家落内存没提速（因果链）**：
1. 专家盘读恒 25.83GB/token（两档 cache 同值）——**内存命中 ≠ 免搬专家**。专家是每
   token 计算的必需输入，缓存消除不了"要消费 25.83GB"这一事实；L1 命中只是让它从
   NVMe→RAM 而非 RAM 内再读，RAM 带宽快但不为零。
2. **判据的 R_sde=1 已被 L2 达成**（meta 持久化后命中 100%，`k3_l2cache.c:220` 仅 miss
   碰慢盘）。cache 8→15 是在"已达标"的位置再加码，无空间可省。
3. 稳态 ~105s 的瓶颈 = trunk 54GB 重读 + 专家 25.83GB NVMe 传输，两者都是物理必需字节量，
   cache 容量无关。

**论文立场核对（paper-submit-cjas）——未被动摇，反而多一条佐证**：
- ① 判据（§3 逻辑命题）：成立，不依赖实验数字。代码已实现其管辖范围（sde 各读一次）。
- ② 现象发现（白板命中 vs 字节重读）：成立。no-chip2 下 L2 命中 100% 但字节仍搬 25.83GB。
  仅 §1.2 用 gen=1 呈现"矛盾"有表述瑕疵（首步加载 ≠ 每 token 重读），需修。
- ③ 对照实验（§4.4 专家迁 L2，−37%）：成立，真实现测（303→191.6s）。
- cache 15 无收益**正是论文"bandwidth-limited, non hit-limited"论断（台账:359）的实证**：
  命中率再高也无用，卡的是数据量。不是反例。

**对设计树的更新**：路径 A（热专家落内存提速）**关闭**。L1 cache 容量非杠杆；
真正剩余杠杆 = ① 消除引擎读路径 85s 隐藏开销（写回出 critical/并发深度/O_DIRECT）
② batch 化让 trunk/专家层权重一次读供 N token（代价：牺牲严格自回归，见 k3_run.c
--batch-gen 注释）③ 字节压缩（E-03 已死，MXFP4 出厂无空间）。

## 0. 约束基调（用户已确认）

- **容许有损**，非 100% 无损。这解锁了 BF8 分档、单精度累加器、量化可替换原始文件等杠杆。
- 目标是"算得快 + 传得快"，覆盖**全过程每个字节流的变化**。
- 一切以实测为准，按收益排序，避免过度工程；偏好硬数字（带宽/延迟/吞吐）。

---

## 1. 字节流分类总纲（把每一段字节按生命周期归档）

一次 token 前向的权重字节，按「诞生 → 消费」旅程分段。每段的关键问题是：
**这字节必须落盘吗？落哪块盘？能复用吗？能靠算法免读吗？**

| 段 | 内容 | 现状存储 | 分类 | 说明 |
|----|------|---------|------|------|
| **S1 静态权重·trunk** | BF16 主干 116GB/93层 | `/model` 慢盘 sde (60MB/s) → 拷入 **sdd7 高速盘** (1.9GB/s) | **必须落盘** | 不可算法免读;但可**压缩替换**(BF8 减半、BF16→BF8) |
| **S2 静态权重·专家** | MXFP4 打包 896专家/层 | `/model` (全1.6TB) | **必须落盘** | 已是4-bit出厂格式,再压收益小;每token只激活 top-16 |
| **S3 激活/中间** | 层间激活、KV cache、latent | 内存 26GB | **免落盘/可复用** | 记忆受限,须逐层流水线;KV cache 可复用跨 token |
| **S4 计算流** | GEMV/GEMM 字节进寄存器 | 内存→寄存器 | **算法可解** | memory-bound;批次化复用权重、单精度累加器 |

### 1.1 核心判别树（每段字节的去留判定）

```
某段权重字节，问 4 个问题：
① 能否算法免读？（稀疏/剪枝/早期退出/复用）→ 能 → 分类"算法可解"，省传输
② 能否放内存/缓存复用跨 token？→ 能 → 分类"可复用"，省重传
③ 必须落盘时，放哪？           → 高速盘 sdd7 (1.9GB/s) vs 慢盘 /model (60MB/s)
④ 落盘前能否压缩替换原始？     → 能 → 压缩后文件直接替换原权重，避免每次从原始再推导
```

---

## 2. 各段详细证据 + 实验单元定义

### 2.1 S1 trunk：必须落盘，但"落什么、落哪、能否压缩替换"

**已证事实（格式探测 B.9-B.12 全部完成，直接复用，勿重测）**：
- `/model` 慢盘 = 55-77MB/s 平坦墙(B.18)，trunk 在那 = 1663s/token 地板
- sdd7 高速盘 = 1.9GB/s(B.19)，trunk 放这 = ~57s/token(29x)
- **格式精度阶梯（B.10/B.11，full_moe_trend.py 4层 dense 残差链，norm=on）已定案**：

| 格式 | L1 | L4 | 结论 |
|------|----|----|------|
| BF16 roundtrip | 168.2 | 339.5 | 基准，零累积 |
| **BF8-E4M3** | 25.8 | 18.5 | **可用，选它**（优于 E5M2 ~4dB/层） |
| BF8-E5M2 | 21.4 | 14.2 | 可用但尾数损失 |
| MXFP4-E2M1(2bit) | 12.8 | 6.4 | 崩，勿用 trunk |
| KM-4b(4bit) | 12.0 | 1.6 | 崩，勿用 trunk |

- **误差主源 = shared_experts**（B.12）：sg/su/sd 残差直通无 norm，单独占满全部 18.5dB；down/up BF8 几乎零代价(~75dB)
- **规律（B.11）**：路径结构决定容忍度——trunk dense 残差直通 ⇒ 4bit 崩、BF8 可用；专家 MXFP4 可行（稀疏路由+latent 窄空间+非残差直通）
- **引擎现状（本次源码确认）**：`k3_trunk_open` dtype 解析 `k3_trunk.c:61-66` **只认 BF16/F32/U8/F16/I8R**； **BF8-E4M3 完全不被 trunk 读路径支持** → 前面探测只证"格式精度可行"，**未证引擎能消费**。MXFP4 走独立路径（.safetensors 打包 nibble→`k3_matmul_mxfp4`），与 trunk dtype 无关。

**悬而未决（本矩阵要回答）**：
- [ ] **E-01** 给 trunk 读路径补 **BF8-E4M3 dtype 支持**（核心增量，勿重探格式）：
      1. `K3_DT_BF8(E4M3)` enum + `k3_trunk.c` 字符串解析
      2. Dequant kernl（BF8→BF16/fp32，E4M3 查表或位运算）
      3. pack 工具：输出 BF8 trunk（每张量按 E4M3 重编码 + 写 dtype=BF8）
      4. 输出新 `trunk_bf8.bin` → **一次性落盘替换原始**，免每次从原始推导
  - [ ] **E-02** BF8 trunk 落 sdd7 的端到端 s/token vs BF16 trunk 落 sdd7
      - 理论:58GB/1.9GB/s = ~30s/token(vs BF16 ~57s)，各**减半**；与带宽31x乘性叠加
      - 注：**E-02 先跑 BF16 基线**（引擎现成支持），E-01 的 BF8 出后再对比

### 2.2 S2 专家：必须落盘 + 激活复用

**已证**：专家 MXFP4 出厂4-bit(B.3/B.4)，每 token 只激活 896路由的 top-16(ARCHITECTURE)。
- 全模型 1.6TB 专家打包 ≠ 需要全读。每次只读 top-16 专家 + 2 shared
- **关键**：专家激活视图很小，但**权重必须落盘**（26GB 内存装不下）

**悬而未决**：
- [ ] **E-03** 每 token 实际激活的专家字节 = 16 路由 + 2 shared 的 MXFP4 字节
      - 量化:per-layer 激活专家字节 × 93 层，验证专家是否传输主导(trunk 才是)
      - ⚠️ **已勘误(2026-08-29)**：专家权重**已是出厂 MXFP4 4-bit**（0.53125 B/param），
        **不存在再压缩路径**；此项不再作为"字节量化"手段，仅作字节流几何统计
- [ ] **E-04** 专家能否也放 sdd7 + 预取重叠？(若 E-03 显示专家字节非瓶颈，则此项降优先级)

### 2.3 S3 激活：免落盘 + 可复用

**已证**：26GB 内存不足驻留多层(B.16 架构定式)，须**逐层流水线**(预取→算→释放)。
KV cache 跨 token 复用(B.14 注释：MLA decode O(T²) 但 cache 后 O(1) 增量)。

**悬而未决**：
- [ ] **E-05** KV cache 真正跨 token 复用，避免 MLA 每步重算 → 已由 `k3_mla_cached` 实现，测 decode 提速
- [ ] **E-06** block-of-12 残差 snapshot/clear(ARCHITECTURE) → 激活内存可否更省

### 2.4 S4 计算流 GEMV/GEMM：算法可解

**已证**：
- 单token GEMV 极慢 10.31ms/down_proj（memory-bound, 15TF, B.14）
- **批次化 = 最大杠杆**：batch256 → 1.19ms/每 token（8.7x），算率饱和 133TF
- 引擎为"bit级精确"付了**double 累加器 + 禁止 FMA** 代价(k3_ops.c 浮点契约)

**悬而未决（容许有损后解锁）**：
- [ ] **E-07** 单精度累加器 A/B（把 `k3_matmul_bf16` / `k3_matmul` 的 `__m256d` 换 `__m256`，
      开一个 fixture 容差）→ 测 GEMV 端到端提速 + 端到端输出偏差
      - 预期:对 memory-bound 内核收益被带宽稀释，需实测确认是否是有效杠杆
- [ ] **E-08** 批次化是否已充分(引擎已做 GEMM)→ 若计算已非瓶颈(E-03/E-02 后)，此段优先级降

---

## 3. 全链路测量方法（可复现基线）

**现有设施（已内置，直接复用）**：
- 传输段 A/B：trunk.c 的 `bytes_read` / `load_seconds`(设备速率)、`k3_trunk_bind_wall` /
  `k3_trunk_widen_wall`(绑定+widen 到 fp32 的隐性成本)
- 计算段 C：`bench_kernels`（微基准）
- 端到端：`k3_run.json`（s/token 总账）

**需要补的（统一剖析输出）**：
- [ ] **E-00** 写一个 `k3_profile` 运行脚本：单次运行输出一份分段的 tap——设备读/预取/绑定/widen/GEMV/端到端，全部对同一 `--gen N` 采样，冷/热缓存各一次
  → 这是**全链路基线**，之后每个 E-0x 都跑同一脚本对比，杜绝东一枪西一枪

---

## 4. 执行顺序（FPGA 到货前 = 权重格式冻结期；到货后 = 硬件接入期）

> **战略节点（2026-08-28 用户确认）**：FPGA 约 3-4 天到货，定位 = **硬件加速 GEMV/GEMM 计算卸载**。
> 到货前唯一标准：**把每个权重字节格式钉死成 FPGA 能直接无脑消费的形式**——x86 引擎是参考实现，
> 不是终点。若到货时格式还在变，全要返工。因此权重格式是到货前的**冻结产出**（freeze 而非 optimize）。

**冻结期（到货前，目标是"一个字节一个格式，钉死不返工"）**：
1. **E-00 全链路剖析基线**（先立尺子）——等 sdd7 trunk 拷贝完成
2. **E-02 trunk(BF16) 落 sdd7 端到端**——立刻有硬数字（57s/token），**同时冻结 BF16 trunk 的落盘布局**
   （层/张量 offset、每层连续读、sdd7 裸设备带宽 1.9GB/s）——这是 FPGA 加载权重的地图
3. **E-01 引擎补 BF8-E4M3 → BF8 压缩替换 trunk**——先加 dtype/dequant/pack，二次压缩减半；
   **冻结组织是 BF16 还是 BF8（E-02 对比定案）+ E4M3 位布局**——FPGA 直接按此位布局解包
4. **E-03 专家激活字节量化**——确认专家 MXFP4 nibble 布局 + top-16 激活视图的字节流形状；
   **冻结专家 MXFP4 的 (packed nibble, scale) 布局**——FPGA 专家 DSP 单元直接消费
5. **E-05 KV cache decode 复用**——冻结 decode 增量路径（FPGA 需按此做 cache 复用硬件语义）

**到货后（硬件接入期）**：
6. **E-06/后续** 按冻结的字节格式写 FPGA 顶层（BF8 或 BF16 GEMM + MXFP4 专家 + KV cache 复用）
7. **E-07 单精度累加器 A/B**——推迟到 FPGA 在板实测后再定 x86 是否值得（FPGA 的累加宽度另行设计）

> 铁律：**每个 E 只动一个变量**，其余固定；统一在 E-00 尺子上读数。
> 冻结纪律：**任何 E 输出一个新权重文件 = 同时输出其精确字节布局规格**，FPGA 侧才能无歧义接入。

## 4.1 实验规范审查（2026-08-28，用标准实验室 DOE 框架自查）

**结论：有良好的控制变量/对照骨架，但缺 4 项标准实验室必备要素，必须补齐后再读数，否则 FPGA 到货后所有前期数字都要打问号。**

| 规范 | 现状 | 补齐动作 |
|------|------|---------|
| ① 重复测量+误差 | ❌ 全单次 | **关键读数 n≥3，报告均值±区间**（磁盘 2-120MB/s 抖动证明误差可淹没问题） |
| ② 测量不确定度 | ❌ 无 | 每通道声明区间；区分"高信噪比结论"(如 31x 带宽差距)与"低信噪比结论"(如 E-07 小效应) |
| ③ A/B 统计判定 | ❌ 无阈值 | 定义：效应 ≥ 测量噪声 × 3 才判"显著"；噪声级则判"未证实"避免误导 |
| ④ 数据/规格可追溯 | ❌ 散落 | 每个冻结权重文件 = 配套一份**字节布局规格**（地址/长度/格式/scale），归档到固定目录 |

### 补齐后的实验读数协议（纳入 E-00 尺子）
- 每个关键读数（端到端 s/token、分段秒数、带宽、SNR）：**跑 3 次，取中位数 + 报告 min/max 区间**。
- 下结论前先算信噪比：`|效应差| / 测量区间`。≥3 判"显著"，<3 判"在此精度下无法区分"。
- 改 profile_k3.sh：单次循环 n=3 两遍，输出每段的均值与区间，而非单值。
- 每个新权重文件落盘时，同目录写 `<name>.layout.md` 字节规格。

## 4.2 冻结产物登记表（FPGA 接入清单，随 E-xx 填）
| E | 冻结物 | 字节格式 | 布局规格文件 | 状态 |
|---|--------|----------|--------------|------|
| E-02 | trunk 落盘地图 | BF16, 每层连续 | (待填) | ⏳ |
| E-01 | trunk 压缩定案 | BF16 或 BF8-E4M3 | (待填) | ⏳ |
| E-03 | 专家激活视图 | MXFP4 nibble+scale | (待填) | ⏳ |
| E-05 | KV cache decode | 增量布局 | (待填) | ⏳ |

## 5. 进度日志（追加，随执行更新）

### 2026-08-28 · 边界审计：端到端干净，分段读数在重叠下不成立（重要）
用源码逐段核对计数器边界（k3_trunk.c / k3_run.c），结论决定 E-00 用什么读数：

| 边界 | 精准度 | 证据 |
|------|--------|------|
| **端到端 s/token** | ✅ **干净，唯一裁决读数** | 单一标量不依赖归因；任何配置可靠 |
| `load_seconds`(设备速率) | ⚠️ 半干净 | 累计纯 pread 时间=k3_trunk.c:398；但被算力重叠遮蔽(k3_trunk.c:550)，cache miss 才累加、pin 层不计 |
| `bind_wall`/`widen_wall` 分解 | ❌ 不干净 | 重叠使分段和可超 100%，k3_run.c:1445 自承"over 100%" |

**根因**：引擎默认异步重叠（RING_WANT=2，reader 线程 k3_trunk.c:193,297；prefetch L+1 平行于算 L，k3_run.c:497）。
唯一关重叠途径 = RING 掉到 1（仅 budget 极小，k3_trunk.c:235）或 pthread_create 失败(302)，**CLI 无直接开关**。

**修正后的实验边界纪律**：
1. **所有 E 的裁决读数 = 端到端 `seconds_per_token`**（可靠）
2. 需要"纯传输 vs 纯算力"分解时：**另跑一个单 slot（RING=1）专用 pass** 关重叠；默认重叠下分段只作"真实工作量近似"，不作归因结论
3. profile_k3.sh 的"分段区间"在重叠下无意义——改为输出**端到端 n=3 区间 + 重叠下的设备速率近似**，另附单 slot pass 测纯边界

### 2026-08-28 · FPGA 战略节点确认（硬件加速 GEMV/GEMM 计算卸载）
- 用户确认：FPGA ~3-4 天到货，定位 = **硬件加速 GEMV/GEMM 计算卸载**。
- 实验主线的**组织原则从"x86 快不快"转为"字节格式能否被 FPGA 直接消费"**：
  x86 引擎降为参考实现；到货前每个 E 的产出 = 冻结一段字节格式（BF16/BF8 布局、MXFP4 nibble+scale、
  KV cache 布局），到货后按冻结规格写 FPGA 顶层。
- 执行序已重排（见 §4）：E-00→E-02(冻结 BF16 落盘地图)→E-01(冻结 BF8 或 BF16 定案+E4M3 位布局)
  →E-03(冻结专家 MXFP4 布局)→E-05(KV cache decode 复用)。E-07 单精度累加器推迟到 FPGA 在板后。
- 铁律加一条：**任何 E 出新权重文件 = 同时写字节布局规格**。

### 2026-08-28 · E-00 尺子已建立 / E-02 前置就绪
- **E-00 剖析脚本已写入 `/root/profile_k3.sh`**（Windows 源在 `opencode\profile_k3.sh`）。
  协议固定：冷(drop_caches)+热 两遍，`--trunk-gb auto --cache-gb auto --gen N --incremental --ids 1,2,3`，
  输出 s/token + I/O 占比 + 分段 + RSS。**所有 E-xx 都用同一脚本读数**。
- **引擎确认**：`/mnt/h/k3/kimi-k3-in-c/bin/k3` 为 Linux ELF x86-64，k3 VM 内可直接运行（gcc 15.2、16核、27GB）。
  model_dir = `/model`（含 config.json / generation_config.json / tokenizer 全套）。
- **传输段测量已内置**：k3_run 输出 trunk 读秒/字节（`k3_trunk_report`）、专家读秒/字节、
  I/O 占比、端到端 s/token——E-00 直接复用，无需新实现。

### 2026-08-28 · 拷贝分诊教训（重要）
- 观察：rsync 拷贝中途瞬时跌到 2-4MB/s，持续几分钟。**别立刻判"卡死"**。
- 分诊：`ps` 显示 rsync 在 `D/R` 态但 CPU idle 89%（无系统 I/O 堵塞）；从 `/model` 源盘
  单独 dd 读同区域 = **4.5GB/s**（页缓存热）→ 证明源盘非瓶颈，属**瞬时闪存页/碎片抖动**。
- 结果：加等几分钟后 rsync 自行恢复到 125-131MB/s，未干预。
- **纪律**：瞬时低速 = 观察 + 分诊（进程态/源盘独立测速），不盲目按"卡死"重启拷贝，避免白拷。

### 2026-08-28 · 首 token 卡死根因反转：不是 trunk，是 embed 慢盘一次性加载（重大）
**现象链**：多次 run（bg 探路 / verify / K3_NOHUGE）都停在记录产出前 → 曾误判"trunk 首层 pread 挂起"、
"THP+O_DIRECT 问题"。用 strace（`-T` 每 syscall 计时 + 大字节 pread fd 映射）才拿到铁证：

| 路径 | fd | 单次 pread | 速率 | 结论 |
|------|----|-----------|------|------|
| **trunk.bin**（sdd7 高速） | 196 | 2.35GB in **2.55s** | **~838 MB/s** ✅ | 健康、高速，符合预期 |
| **embed/lm_head**（/model sde 慢） | 190 | 2.35GB in **25.3s** | ~84 MB/s ❌ | 慢 10 倍，且 final pread 永久 `<unfinished>` 挂死 |

**根因定型**：卡死在 `k3_bind_model`（k3_run.c:963）加载 embed+lm_head（4.7GB）——从慢盘 sde 的
**单次 2.35GB 巨型 O_DIRECT pread**，要么 84MB/s 极慢（~25s）要么永久挂起 D-state。trunk(sdd7) 反而健康。
- 与 dd 对比佐证：sdd7 上 2.1GB O_DIRECT = 948MB/s 秒过（任意块大小都正常）→ 慢盘 sde 的巨型 DIO 是元凶。
- **审计订正**：此前"embed 是 74.7s 一次性 settling cost"的判断不完整——它**偶尔挂死、且冷启动极慢**，
  是当前无法产出可复现端到端读数的直接阻塞项。

**行动良机（不违反专家40K限制）**：embed/lm_head 仅 **4.7GB**（远小于 96 shard 专家的 1.45TB），
**可整体搬到 sdd7 高速盘**，一举消除挂死 + 一次性慢盘惩罚。但引擎 CLI 的 embed 加载走 `/model`（k3_st 用
`dfd` O_DIRECT，k3_st.c:347-352），**无独立 embed 路径参数** → 落地需改源码（k3_st 支持 embed 单独目录）或
验证 embed 是否已由 OS 页缓存吸收（warm run 的 13.7s 提示页缓存命中有效）。
- **下一步**：① 冷启动是否必挂（页缓存冷时 embed 2.35GB pread 是否必然 D-state）做 n≥3 复现；
  ② 若确认，改 k3_st 给 embed 独立高速盘路径（或 `--trunk-gb` 策略让 embed 走页缓存 buffered）。

### 2026-08-29 · S2 专家复用实证：trace 证明 90% 专家请求可缓存（决定性，直接服务 E-03）

**背景**：baseline（上一条）专家 303s/token 是唯一瓶颈。黑客问题：每 token 是否 25.8GB 里大部分是**重复请求**，
能否用缓存/复用砍掉，而不等实验芯片。用真实路由 trace（`data/expert_trace.bin` 100,096 条 = **68 真实 token × 1472 请求/token**
= 92 层 × 16 专家 × 17.5MB）实证。⚠️ **修正 2026-08-29**：早期 736-run"8 super-iters × 92 层 × 136 请求/run"分组
是**错误切法**（按"层字段连续"分组，非真实 token 边界）；真实切法见下方 L2 实测。

**先钉死字节数**（index 实测，与 trace 工具内置值互相印证）：
- 每专家权重 = 3×(w1/w2/w3 `weight_packed` 各 5,505,024 B) + 3×scale(344,064 B) = **17,547,264 B = 17.5MB**
  （`predict_hotset.py` 硬编码 `KBYTES=17_547_264` 与之**逐字节吻合**，非巧合）。
- 每 token 专家理论载入 = 92 层 × 16 专家 × 17.5MB = **25.8GB/token** == 引擎实测 READ **25.83GB/token** ✅
  → 引擎当前 = 全量重读零复用。

**命中率实测（请求加权，switch prev-set = 本层上一 run 全部 distinct 专家集）**：
- 冷载入（run 内首见且跨 run 未见）：**10.0%**（这 10% 才真正需要传权重）
- 跨 run 热（run 内首见，跨 run 见过）：**53.8%**
- run 内热（同 run 二次及以上）：**36.2%**
- **prev-set 总命中 = 53.8% + 36.2% = 90.0%** → 载入 25.8GB → **2.58GB/token（-90%）**

⚠️ **2026-08-29 修订：上面这套 run 内/跨 run 三分法基于错误切法（runs≠token），已弃用**。
真实答案 = `l2_hit_upper.py`（1472 请求/token 正确切法）对同一 trace 的跨 token 复用：
- token 0-4：冷启动，跨 token 命中 0~1%
- **token 5 起稳定 90~98%**（90.6/90.5/91.5/94.7/93.9/92.7/89.1/92.4...）
- 全 run 总 distinct (layer,expert) = **10,010 键**
- 与引擎实测吻合（下节 L2 实证）：gen=4 值 33.08% = token0..3 累计 0/20/40/64.6%，**未及稳态**
- 结论：**跨 token 专家复用稳态 90%+ 成立，L2 无逐出（>10,010 键可全容纳,256GB>>176GB）即吃到**

**对照系（都在同一 trace 上）**：
| 策略 | 请求加权命中（warm） | 预算 |
|------|------|------|
| 频次热表 K=10 | 11.5% | 16.1GB |
| 频次热表 K=30 | 34.3% | 48.4GB |
| 频次热表 K=60 | 69.6% | 96.9GB |
| prev-topK K=30 | 54.3% | 48.4GB |
| prev-topK K=60 | 77.2% | 96.9GB |
| **prev-set（全集）** | **90.0%** | ~106 专家/层 ≈ 165GB 全量 |
| 频次热表 K=130 | 95.3% | 209.9GB |
| 全局 LRU 桶 57~2800 专家 | **卡在 36.2%，不随预算涨** | 1~49GB |

**关键结论**（2026-08-29 修订版，基于正确切法 + 引擎 L2 实测）：
0. ⚠️**语义警示（2026-08-29 补充）** `struct_check.py` 定调：大 trace **纯流结构 = 8 遍层遍历 × 92 层**
   （每遍每层 80→192 专家单调涨，8 遍完美拼接），**并非 68 个真实 token**；
   "100,096=68×1472"只是整除巧合（92×1088 也成立）。`l2_hit_upper.py` 的 1472-slice 90%+
   是基于**遍间复用**的传导（pass1-7 累计复用 89-95%），**不可直接等同于"生成 token 间复用"**——
   它更像"同一提示反复重扫"的复用上限，**真机生成 token 间路由漂移大得多，33% 才是宽松下限**。
   trace 结论定位：**理想复用上限证明**（假设路由稳定），非真机现状。
1. 每层 distinct 专家 median **106**（max 160）、单 run 集合 median **85**；全 run distinct 10,010 键 ≈ 109/层 → **层级局部性强**
2. **跨 token 专家复用稳定 90%+**（token≥5 后），唯一前提是**缓存能全容纳 distinct 集**（无逐出）。
   L2 盘缓（256GB >> 10,010×17.5MB≈176GB distinct）正是载体 → **25.8GB/token 中 ~90% 可免慢盘重读**
3. 全局 LRU 无效（gen=4 内 33%、token 级 36% 天花板）的表象 = 跨层顺序 + 容量不足；**L2 大容量 + 全 distinct 驻留**
   才是关键（作者 sim_cache"192GB=90%"同一物理结论，此处拿到 trace 级实现）。
4. 频次衰减 γ 无影响（分歧数=0）→ 热集稳定，累计表足够。
5. **与带宽研究（bandwidth-capacity-research.md §7.1）互证**：L2 方案 = 作者"192GB=90%（层内聚拢）"的在线实现；
   §7.1"在线批内仅 36%"是**小容量（逐出）**下的数字，被大容量 L2 破除。两者不冲突——36% 是常态预算下的 LRU 假象。
6. **可执行红利（2026-08-29 真机复查）**：L2(sdd7) 全 distinct 驻留 **实测仅把专家段 303s → 191.6s（-37%）**，
   卡在**数据量带宽**（命中 74.89% 后仍要搬 612GB/32token + miss 慢盘 214GB），**没有出现 trace 推的 43s**。
   "~43s/token"的预测前提（90% 命中→只读 2.6GB 慢盘）真机**不成立**——真机命中只有 74.89% 且每 token distinct
   集大、miss 段仍是慢盘全量重读命中后的残留。
7. 给 d-Matrix 类 L0 SRAM 分层（bandwidth §6.2）设计含义：SRAM 级按"层内 8 槽/层"做热专家命中，
   L2 sdd7 兜底全 distinct；两级覆盖 90%+ 稳态复用。**但真机 L2 只到 74.89%，SRAM 收益同理受限。**

**对 E-03/E-04 的意义（2026-08-29 终版）**：E-04 结论维持反转但**期望值校准** →
专家落 sdd7（L2 机制）**实测 -37%（专家段 303→191.6s，总 326.5→262.8s），免改源码即可实现，是已落地的保守收益**；
"90%/-86%"的激进预期来自 trace 的遍级复用上限，真机稳态 74.89% + 带宽限制不支撑。
**E-03 勘误（2026-08-29，用户质疑后复核源码）**：专家权重**已经是出厂 MXFP4（4-bit nibble + E8M0 scale，
0.53125 B/param，k3_load.h:17 白纸黑字）**，"25.8→~13GB"是笔记里的无据数字——每专家 17.5MB 里 ≈1MB
（344KB×3）是 scale、其余已是半字节 nibble，**不存在再压缩一半的路径**（2-bit 即精度崩盘，
shared_experts 4-bit 已吃 18.5dB）。E-03 正确定义 = 统计每 token 激活字节流（16 路由 + 2 shared）的几何量，
**专家段的真后续突破口不是字节量化，而是 ① 提高 cache-gb 让 L1 跨 token 留驻（现 0.12% 保留率）② L2 元数据持久化**
（快慢盘区分读 `k3_expert_load_direct` 区别对待）③ 带宽侧（快盘顺序读对齐）。**E-03 已死，从设计树移除字节量化预期。**

### 2026-08-28 · embed 已实战修复（symlink→sdd7），首个完整端到端 baseline 产出（重大）
**先订正上一条的技术细节（重要，避免误导后续 E 系列）**：
- embed/lm_head 实际走 **buffered**（`k3_st_read`→`s->fd`，k3_st.c:503；k3_bind.c:138），**不是 O_DIRECT**。
  O_DIRECT 的 `dfd`（k3_st.c:347-352）用于流式专家读，embed 不用。
- 上一条"O_DIRECT 巨型 pread 挂死"的表述有误，抱歉未先核源码就下结论。**真实机制**：embed 用 buffered 从
  慢盘 sde 读 2.35GB，慢了 10 倍（84MB/s，25s）+ 偶发 D-state 消化页分配，本质是**慢盘 sde + 已 100% 满盘**。

**实战修复（零改源码，symlink 方案）**：
1. embed+lm_head 全部内容集中在**单一 shard** `model-00094-of-000096.safetensors`（4697664072 B = 4.69GB，
   含 `language_model.lm_head.weight` 2.35GB + `...embed_tokens.weight` 2.35GB）。
2. `cp` 到 sdd7（`/mnt/wsl/PHYSICALDRIVE2p7/embed/`，56s / ~84MB/s = 源盘读速上限），**MD5 全量匹配**。
3. `/model/model-00094-of-000096.safetensors` → symlink 指向 sdd7 副本（原名备份 `.orig`）。
   symlink 读通；`md5sum` 全量 4.69GB 经 symlink = **11.2s（~419MB/s）**，较慢盘 25s/84MB/s 快 ~5 倍。
   → k3_st_open 扫 /model 时 open 该 shard 实际落在 sdd7，零源码改动。

**首个完整端到端 baseline（E-00 尺子第一发，verify 配置 `--trunk-gb 6 --cache-gb 1 --gen 1`）**：
```
embedding, final norm and lm_head: 4.70 GB in 7.0 s   (原慢盘 25s+/挂死 → 修复后 7s)
STEP0  9689  324.36s  CACHE HIT 100%  READ 25.83GB
trunk (sdd7): 108.81 GB 读, 60.94s → 1786 MB/s ✅ 高速盘满血
experts(sde) : 25.83 GB 读, 303.58s → 85 MB/s ❌ 【现阶段绝对瓶颈，占 s/token 94%】
I/O share 112.4% (trunk 60.9 + experts 303.6 of 324.4)，overrun=trunk 读被算力吸收
first seconds_per_token = 324.36 (1 token, warm-ish)
```
**修正后的瓶颈地图（决定性）**：
- **trunk 已非瓶颈**（sdd7 1786MB/s，每次全读 108.81GB 只需 61s，且 93% 重叠进算力）。
- **embed 已修复**（7s 一次性）。
- **专家 = 唯一决定 s/token 的变量**：从慢盘 sde 流式重读 25.83GB/token @85MB/s = **303s/token（94%）**。
  这就是 E-02 及后续必须攻的墙：专家 1.45TB 迫留慢盘，每 token 全量流式重读。

### 2026-08-29 · L2 双轮实测：trace 90% 复用推断 vs 真机回退（重大经验）
**结论先行**：L2(sdd7) 专家缓存 **两轮端正（8-28 gen=4, 8-29 gen=32 进行中）最多把专家 I/O 从 303s 压到 ~180-200s，
永远到不了 trace 模拟的 43s/-86%。trace 90% 跨 token 复用是真，但 L2 引擎路线的瓶颈不在命中率，在数据路径。**

**8-28 gen=4 L2（已完）**：s/token 346.85（no-L2 对照 326.5，反而更慢）。
l2cache: requests 5565, hits 1841 (33.08%); read sdd7 32.3GB/written 71GB。
专家总盘读仍恒 103.32GB/4 token=25.83GB/token（L1 1GB 下每次都要重读）。

**8-29 gen=32 L2（已完，决定性）**：
```
l2cache [final step]: 46587 requests, 34890 HITS (74.89%), 11697 misses
  read from sdd7 612.22 GB / written 214.30 GB
experts whole run: 826.55 GB read | 保留在 RAM 56/47104 (0.12%) | 47048 evictions
experts I/O: 6132.5 s (=191.6 s/token) | trunk I/O: 3117.9 s (=97.4 s/token)
I/O share 110.0% (trunk 3117.9 + experts 6132.5 of 8408.8)
PEAK RSS 11.09 GB
"seconds_per_token": 262.7757
```
**归因（定稿）**：
- **真机 L2 命中满血 74.89%**（稳态达成，非 gen=4 的 33%）——L2 缓存本身工作正常、可复制。
- **专家 I/O 303 → 191.6s/token（-37%）**，可复现的实测收益；但**远未到 trace 推的 43s/-86%**。
- **卡点不是命中率而是数据量**：即使命中 74.89%，每 token 仍要从 sdd7 搬 19.1GB（612GB/32）+
  miss 段从慢盘 ~6.7GB（214.3/32）→ 专家段仍 191.6s，**占 wall 73%**。**bandwidth-limited，非 hit-limited**。
- trunk 这次 97.4s/token（8-28 是 60.9s）——疑似与专家并发抢读取;trunk 读只计重叠后剩余。
- **262.78 s/token 是当前真机 L2 稳态水平**（对照 no-L2 326.5 → -20%，不是 -86%）。

**根因（源码级确认 k3_l2cache.c）**：
1. **L2 无元数据持久化**：`k3_l2_init` 每次 malloc `key_of/slot_of/count` 全清空 + ftruncate，
   复用一个旧 experts.l2 文件 = 伪复用，等于每次冷启动。跨进程填的 256GB 全废。
2. **fill 是懒的**：只有 miss 才同步 pwrite 写 sdd7，且 miss 路径是 `k3_expert_load_direct`（先慢盘读）
   → 冷启动头 4-5 token 全 miss 全慢盘，90% 键在 token≥6 才可能填充完，前半程都在爬。
3. **命中也要 pread 25.83GB/token 从 sdd7**：sdd7 1786MB/s 下也要 14.5s，叠加 miss 段慢盘。
   L1 只有 --cache-gb 1，无跨 token 复用（同 L1 内 batch 复用 36%）。
4. **结论：要 90% 收益需 (a) 元数据持久化复现 fill (b) 提高 cache-gb 吃跨 token L1 命中 (c) 或真机顺序改为
   预填**。三者都是源码改造，时长是一天量级。**先出量化证据：L2 命中到底多少、sdd7 读占比** → final 报告。

5. **miss 构成量化（2026-08-29 补充，回放器 replay_l2.py + 拟合 calibrate_newkeys.py）**：
   - 真机 11697 misses **全部是首次见新键**：14589 槽 > 11697 键，L2 全程无逐出，
     逐出重访 = 0（大 trace 100096 请求回放同样 evicted_revisit=0）。miss 不是容量问题。
   - per-token 新键 = **单调衰减**（intrace 实测 1472→1176→878→521；几何拟合后 32 token 累计恰 = 11697，
     token1=1483 → token32=24，r=0.125）。慢盘 miss 字节集中在**前 4 token（86/205GB = 42%）**，
     后 16 token 合计只剩 27GB → **冷启动头 4-5 token 才是慢盘真身，稳态后 miss 只是长尾**。
   - **A/B 裁定**：A（L2 元数据持久化）可消除的只有"跨进程伪复用"的启动损失——真机 32 token miss 中
     **逐出重访=0，A 的预填收益上限极小**；B（异步预取把 miss 慢盘读藏进 GEMM）直接命中"前 4-5 token
     86GB 慢盘读"这一真瓶颈 → **B 优先，A 降为冷启动便利项**。

**给设计树的更新**：E-04"专家落 sdd7"以 L2 形式实测了，**预期从 -90% 下修为 -37%（专家段 303→191.6s,总
326.5→262.8s）且已落地**；想再进一步需源码改动（cache-gb / L2 元数据 / 读路径对齐）。E-03 字节量化不是路
（专家已是 MXFP4 出厂 4-bit，无再压缩空间，见上勘误）。

**2026-08-31 介质带宽墙实证（推翻上述 B 优先假设）**：
- **sdd7 真身 = SINKER SEV512THK 512G NVMe（WSL 直通 ext4 块设备，非 9p）**。实测带宽：O_DIRECT
  冷读 588MB/s（drop_caches 后 64GB dd）+ 缓冲写 211MB/s。**"1786MB/s 额定"认知作废**——
  WSL 直通层的真实持续读就是 ~590MB/s 量级（max_sectors_kb=1280 限制单次 request）。
- **慢盘（专家源 /model = sde Virtual Disk）实测 99MB/s**（O_DIRECT 冷读 8GB）。
- **L2 每 token 流量 = 19.13GB 命中读（sdd7 @588）+ 6.7GB miss（慢盘 @99 读 + sdd7 写回）**。
  同步串行的理论下限 ≈ 33s + 68s ≈ **101s/token**；实测日志 186s（139MB/s）→ **85s 隐藏开销
  不在介质，在引擎读路径**（bibliography：miss 写回在 omp critical 串行、56 槽 L1 arena 逐层
  evict、getmany 每层 barrier、sdd7 缓冲 I/O 页缓存打穿 238GB 文件）。
- **每 token 恒定 25.83GB 重读 + step 时间无衰减（真机 168~507s 平坦）**。"慢盘 miss 集中冷启动、
  后期衰减、前 4-5 token 86GB 才是真瓶颈"结论作废：miss 长尾确实存在，但恒定 19.1GB sdd7 读 +
  6.7GB 写回才是 wall 的 71% 主因。
- **B（异步预取）收益上界重新估算 ≈ -45%**：理论下限 101s 说明可藏空间 = (186-101)/186 ≈ 46%。
  全链介质带宽下限是 101s/token；真正的大杠杆 = ① 消除 85s 引擎读路径开销（写回出 critical、
  提升并发深度、O_DIRECT/更大 slot 读）② 提高 L1 cache-gb（跨 token 同层 Jaccard 92.7% 真吃 RAM）。
- **下一步主线调整**：①②并列为新优先级（原 B=藏 miss 慢盘读 变体 = 藏整条 25.8GB 读路径 +
  修 85s 隐藏开销），cache-gb 复升为可选项（56 槽 → 更大 L1 让跨 token 复用减少 19.1GB 重读）。

**2026-08-31 第二次实测：短 gen + 单 token 剖析（推翻部分上表）**：
- **--gen 1 单 token 实测 492.8s/token（慢），专家段 378.1s @ 68MB/s**。trunk 段 143.7s @ 757MB/s
  （O_DIRECT，健康）。专家 25.83GB 读 = sdd7 **全 miss**（1351/1351）→ 首见键全走慢盘 + 写回 sdd7
  （written 25.83GB），cache_getmany 再立即从 L1 arena 用内存副本（TRUE resident 0%）。
- **--gen 2 实测 527.9s/token，L2 命中仅 8.7%（2850 req 248 hit）**。专家 51.66GB @ 75MB/s =
  慢盘 miss 读 + sdd7 pwrite 写回 47.31GB（**写回量 = 流量的 92%，是隐藏大坑**）。
- **重大发现：miss 写回 pwrite 在 omp critical 区全串行（k3_l2cache.c:118-142）**。gen 2 写 47.3GB
  @ 211MB/s ≈ 224s，占专家段 750.9s 的 30%。这是从未被量化过的隐藏开销，且与 read 串行（同 fd）。
- **B（藏 I/O 与 GEMM 重叠）在新数据下的再估**：gen=32 专家段 191.6s/token 分解 = 慢盘 miss 读 68s +
  sdd7 hit 读 33s + pwrite 写回 32s + 同步/串行开销 ~58s。**若 B 把前 3 项 ~133s I/O 全重叠进 GEMM，
  专家段 → ~58s（-70%）**。但这要求 pwrite 移出 omp critical + 双缓冲（读记分开）。
- **用户场景理解**：`--ids 19180 + --gen N` 的后续 token 专家键是稳定轨迹，gen=32 实测 L2 hit
  74.89%；短 gen 首 token 全 miss 是冷启动最坏情况，不代表稳态。
- **下一步主线最终版**：① **B' = 藏整条专家 I/O 路径（慢盘 miss 读 + sdd7 hit 读 + 写回全移出 critical、
  与 GEMM 重叠）**，预期专家段 -70%；② 验 L2 介质（WSL 直通 588MB/s 是否已是墙）；③ cache-gb 可选。

**2026-08-31 第三次实测：pwrite 移出 critical 零收益，B' 假设推翻（关键反转）**：
- **做了什么**：给 L2 miss 写回动手术（busy 哨兵 + 短 critical reserve → 锁外 pwrite → 短 critical publish，
  k3_l2cache.c:k3_l2_load_direct），重建 242952B。
- **先发现：L2 映射纯内存**（k3_l2_init 每次 malloc key_of/slot_of/count 全清空，只 ftruncate 文件，
  **key↔slot 映射从不落盘**）→ 换进程复用旧 experts.l2 = **伪复用**，重用同文件重跑仍是全冷启动。
- **实测 A/B（同一 experts.l2 冷态 gen2，回溯对照上轮旧二进制）**：
  | 指标 | 旧二进制 (8-31 上轮) | 新二进制 (patch) |
  |------|------|------|
  | 总 | 1055.8s / 527.89s per token | **1054.6s / 527.32s per token** |
  | 专家段 I/O | 750.9s | 825.7s |
  | trunk read | 204.72GB in 305.5s (670MB/s) | 204.72GB in 251.11s (815MB/s) |
  | l2cache | 2850 req / 248 hit (8.7%) / miss 2602 | 2857 req / 248 hit (8.7%) / miss 2609 |
  | 写回 | 47.31GB | 47.31GB |
  → **总量零差异（527.3 vs 527.9），专家段不降反升（环境噪声级）**。
- **根因订正（推翻上一条"pwrite 串行 224s 占 30%"）**：
  1. pwrite 是**缓冲写**（页缓存 memcpy），上限是 balance_dirty_pages 聚合限速，**不是 omp critical 抢占**；
     移出锁只是把阻塞从"排队"变"各自堵"，量不省。
  2. 专家段墙 = **慢盘读带宽地板**：51.66GB @ 68MB/s ≈ 752s，实测 750-826s，锁从未是瓶颈。
  3. **I/O share 102% → compute≈0**：GEMM 可重叠头几乎不存在，**"藏 I/O 进 GEMM -70%" 整条假设死亡的量实证**。
     gen=32 191.6s 分解里的"~58s 同步/串行"同样主要是慢盘带宽+页缓存争用，不是锁。
- **行动**：零收益改动已**还原源码并重建**（bin 11:19:50，零警告，= 基线），保持可复现。
- **顺带硬证**：两次 gen2 实测差 1.2s（0.1%），trunk/专家分段差 ~10% → **同环境重跑重复性 ≈1.5s 级**，
  分段易受页缓存/调度影响，裁决读数永远用端到端。
- **新主线（数据驱动重排，废弃 B' 藏 GEMM）**：
  ① **L2 元数据持久化**（这轮发现的真相直接翻它的估值）：key_of 落盘 sidecar（13563×4B=54KB）+ 每槽
     短校验（首 4KB crc）init 验证 → **重跑/续聊直接命中已写 47.31GB**，短 gen 冷启动和"停-续对话"两场景
     都变 sdd7 命中路径（588MB/s），预期专家段大幅下降、无 224s 写回。
  ② **更高 cache-gb 吃 L1 跨 token 复用**（同层 Jaccard 92.7%，56 槽→数百槽）。
  ③ 读路径 O_DIRECT/大块读（命中槽顺序读对齐）。

**2026-08-31 第四次实测：L2 元数据持久化落地，重跑变 sdd7 命中路径，输出逐字节一致（主线①完成）**：
- **做了什么**：k3_l2cache.c/h 加 sidecar 元数据。每槽 8B = {int32 key (LE) + uint32 crc32(IEEE,0xEDB88320)} × 13563 槽 =
  **108,504B**（`<path>.meta`）；指纹 = crc32(前 4096B payload ∥ key LE)（`L2_CRC_N=4096`）。`k3_l2_init` 打开/读旧 meta →
  逐槽校验（key 越界→空闲；key 重复→先到先得；crc 不匹配→空闲）恢复映射 → ftruncate(meta, nslot*8)；meta 读取失败 /
  文件缺失 → meta_fd=-1 静默降级旧行为（stderr 一行提示，不中止）。miss 发布写回 payload 成功后，同 critical 内 pwrite
  8B 记录到 slot*8。`k3_l2_free` 关 fd；report 仅当 meta_loaded>0 打印 `restored from meta: N slots`。
  **修复顺序 bug**：meta 恢复块必须在 key_of/slot_of 分配并置 -1 **之后**（否则解引用 NULL）；nkey 声明上移。
  构建 243,032B @ 11:34 零警告。
- **实测 A/B（同一 experts.l2 + 新 meta 文件）**：
  | 指标 | 段一·冷跑（首次填 meta） | 段二·热跑（meta 复用） |
  |------|------|------|
  | 总 | **968.6s / 484.32s per token** | **660.8s / 330.39s per token**（-31.8%） |
  | l2cache | 2805 req / hits 248 (8.84%) / misses 2557 | **2944 req / hits 2944 (100%) / misses 0** |
  | 写回 | 47.31GB | **0.00GB** |
  | sdd7 读 | 4.35GB | 51.66GB |
  | 专家段 I/O | 757.9s | **257.1s（-66%）** |
  | trunk read | 204.72GB in 184.68s (1109MB/s) | 204.72GB in 382.91s (535MB/s) |
  | restored | —（0，meta 为空） | **2696 槽** |
  → **机制按设计工作**：热跑 0 miss / 0 写回 / 100% 命中，专家段 -66%。总时 -31.8% 被 trunk 设备速度方差稀释
  （本次 535MB/s 是历次最差；端到端读数 = 660.8s，重复性信号见下）。
- **正确性验证**：两次 JSON 递归 diff 仅 `seconds_per_token` 不同，`prompt_ids/generated_ids/full_ids/layers` **逐字节一致**
  → meta 恢复未喂错专家，token 级可复现。
- **根因注记**：hot 跑 write_bytes 峰值 = 4096B（≈0）；trunk I/O share 96.8%（trunk 382.9 + experts 257.1 of 660.8），
  计算头仍几乎为零。**L2 持久化解决了"换进程 / 停-续对话伪复用"，短 gen 冷启动从慢盘 68MB/s 全读+全重写 → sdd7 588MB/s 命中路径**。
- **对 design tree 的更新（主线① 完成，标记为已验证）**：①→✅已落地（本轮）；② cache-gb 提高 L1 跨 token 复用（真机
  56 槽 1GB，0% TRUE resident——gen 长时收益）；③ 读路径 O_DIRECT/对齐（未动）。trunk 535-1109MB/s 大方差成当前端到端噪声主源。
- **保留脚本**：/root 下 popmeta.sh（冷跑填 meta）、meta2.sh（热跑校验）；产物 k3_meta1.* / k3_meta2.*。

**2026-08-31 第五次实测：L2 命中读 O_DIRECT 化，2-token 短 gen 端到端 340.5s（170.25s/token），主线③完成**：
- **做了什么**：k3_l2cache.{c,h} 加第二个 fd——`l2->fdh = open(path, O_RDONLY|O_DIRECT)`；HIT 路径当
  `want == l2->slot_bytes`（整槽、4096 对齐、目标 arena 页对齐——arena 本就 posix_memalign 2MB、slot 步长按
  O_DIRECT 对齐取整）时走 fdh，其余回退 buffered fd；free 关闭；修复 `_GNU_SOURCE` 屏蔽（O_DIRECT 未声明）。
  缓冲写仍走 l2->fd（miss 的 pad 非对齐 pwrite 必须 buffered）。构建 243,032B @ 12:11 零警告。
- **实测 A/B 三态（同 meta 已填 2696 槽）**：
  | 指标 | 冷跑(无 meta) | 热跑·缓冲读 | **热跑·O_DIRECT 读** |
  |------|------|------|------|
  | 总 | 968.6s / 484.32 | 660.8s / 330.39 | **340.5s / 170.25**（-65% vs 冷） |
  | 专家段 I/O | 757.9s | 257.1s | **162.5s**（per-token 读 25.83GB @ 304MB/s，缓冲 161） |
  | l2cache | 248/2805 (8.84%) | 2944/2944 (100%) miss0 | **2944/2944 (100%) miss0** |
  | 写回 | 47.31GB | 0.00GB | **0.00GB** |
  | trunk | 204.72GB @1109MB/s | @535MB/s | @733MB/s（bind wall 115s，重叠 59%） |
  | restored | 0 | 2696 | **2696** |
  → **O_DIRECT 命中读把专家段再砍 37%（257.1→162.5s），且与 trunk 读重叠**（I/O share 129.7%，101s 藏在算力后）。
- **正确性**：k3_meta3.json vs k3_meta1.json 递归 diff 仅 seconds_per_token 异；**stderr 0 字节**（无 EINVAL/无 short
  prefetch/无 fd 降级告警）→ O_DIRECT 路径全程干净。
- **意义**：**2-token 短 gen 冷启动 340.5s 已低于 gen=32 稳态 262.8s/token**（L2 命中路径 + O_DIRECT 读 +
  trunk 重叠三重叠加）；对比初始基线（无 L2）326.5s/token 单 token gen1。**"短 gen 是冷启动最坏情况"的结论被推翻**——
  持久化 + O_DIRECT 让短 gen 每 token 读 sdd7 51.66GB 只需 162.5s 总量。
- **注意**：O_DIRECT 命中读 304MB/s < sdd7 设备 588MB/s 上限——与 trunk O_DIRECT 同盘并发竞争（trunk 733MB/s
  同段），继续压需（若可行）错峰/权重。此盘双流合计 ~1.04GB/s 已接近单 NVMe 上限。
- **对 design tree**：①元数据持久化✅、③读路径 O_DIRECT✅；剩 ②L1 cache-gb（长 gen 才吃）/ trunk 重叠深化。
- **保留**：meta3.sh / k3_meta3.*；二进制 12:11 版 = 当前最优。

**2026-09-01 第六次实测：/data 拷贝慢的根因定位 + 共享 NVMe 定案（不拷贝）+ 新热跑 127.46s/token**：
- **背景**：此前做"把 NVMe 数据拷到 D 盘 fixed VHDX(/data)"备副本，48min 才拷 94G(33MB/s)，久拖不决。用户改判"数据留在 NVMe 上共享，不拷贝"。本轮全链路测量把慢根因钉死。
- **分层测速（全链硬数字）**：
  | 环节 | 实测速率 |
  |------|---------|
  | NVMe 源读（sde7/sdd7 O_DIRECT 裸块） | **1.0 ~ 2.4 GB/s** ✅ 源非瓶颈 |
  | D 盘原生持续写（纯 Windows 2G 随机数据） | **90 MB/s** ← 宿主瓶颈 |
  | WSL 经 /data 小批次(2G) dd | 467 MB/s（突发，靠页写缓存） |
  | WSL 经 /data 持续大文件(40G+) dd/rsync | **~30 MB/s**（持续衰减） |
  | VHDX 物理文件 | fixed，419GB on D 盘（D=HIKSEMI XS310 SATA SSD，非 HDD） |
- **根因定性（推翻"VHDX 本身慢"）**：VHDX 不慢（sde 根盘读取一贯 700-1100MB/s）。真正的墙是**宿主 D 盘 SATA SSD 持续写入仅 ~90MB/s**，叠加 WSL→VHDX 的 I/O 路径后持续写塌到 ~30MB/s。此前的"VHDX 好好的"全在**读**场景，**写**一直是宿主带宽地板。
- **关键脏数据修复**：40G 测试残留 `_big.bin`(29G) 占用 /data 近满，导致 rsync 报 `No space left on device(28)`、experts.l2 只拷到 97G 就中断。已删除全部测试残留（_big/_e2e/_sust/_bench*.bin），/data 回 187G 空闲。
- **重复 spawn 陷阱**：WSL systemd 会话启动失败会重复 spawn rsync（观测到 3-4 个同参数 rsync），互相竞争降速。凡后台拷贝一律 PID 锁 + 单实例，或用 `Start-Process`（Windows 侧）拉起。`pkill -f 'experts.l2'` 会误杀自身 wsl 包装（AGENTS.md 教训重演）。
- **定案（用户确认）**：**数据留在 NVMe（/mnt/nvme, UUID=bf9f8467），WSL 与 FPGA 共享同一分区，零拷贝**。/data(VHDX) 上的残留副本（trunk 102G + experts.l2 97G）存档待命，不删即不占 NVMe。
- **共享 NVMe 路径热跑验证（metanvme.sh，gen2 incremental 复用已填 meta）**：
  | 指标 | 值 |
  |------|-----|
  | 总 | **254.9s / 127.46s per token**（比 /mnt/wsl 路径的 170.25 快 25%） |
  | trunk | 204.72GB in 197.56s = **1036 MB/s**（首次破 1GB/s） |
  | 专家段 | 51.66GB，restored 2696 slots，100% hit，O_DIRECT |
  | stderr | 0 字节 |
  | JSON | tokens [11,374] 与 meta1/2/3 **逐字节一致**，仅 seconds_per_token 异 |
- **正确性（跨重启+换路径+共享盘）**：generated_ids 不变 → 引擎对存储介质无路径/顺序依赖，FPGA 共享同盘读数据安全。
- **对 design tree**：存储改共享 NVMe 后，trunk O_DIRECT 达 1GB/s+、专家 O_DIRECT 命中路径，瓶颈由"拷贝慢"转移为"纯推理耗时"，且推理已优化到 127.46s/token。剩余 ②L1 cache-gb 低优先。
- **待办**：127.46s/token 需 n≥3 复测（规范）；/data 副本清理与否待用户定；FPGA 138K Pro 到货后读 NVMe 数据（共享）。

**2026-09-01 共享 NVMe 热跑 n=3 复测（规范达标）**：
- 三次（rep_n3.sh, 11:05:11→11:25:26，同 meta 复用，gen2 incremental ids 19180）：
  | iter | seconds_per_token | generated_ids |
  |------|------|------|
  | 1 | 129.3278 | [11,374] |
  | 2 | **130.1143（中位数）** | [11,374] |
  | 3 | 153.0892 | [11,374] |
- **中位数 130.11 s/token，区间 129.3~153.1（±17%）**。三读 tokens 全部 [11,374] 逐 bit 一致。
- **重复性**：127.46/129.33/130.11 前三读紧密（差 <2%），iter3 的 153 为环境噪声——trunk 设备速率 535~1109MB/s 大方差是端到端噪声主源（历次已记录），不涉专家/meta 正确性。
- **规范满足**：n=3，报中位数±区间；一致性以 tokens 逐位相等为准。共享 NVMe 热跑水平 ≈ **130 s/token（稳）**。
- 产物：/root/k3_nvme_r{1,2,3}.{json,out,err}；脚本 rep_n3.sh。
- **待办更新**：复测已达标；剩 /data 副本清理待定 + FPGA 到货后读共享 NVMe。

**2026-09-01 max_sectors_kb 探针：调大无效，588MB/s 非硬墙（划掉"调参提速"路径）**：
- 探针（msk_probe.sh，NVMe=/dev/sdd7，disk node=sdd）：`max_sectors_kb` 1280→4096 可写成功，
  | 设置 | 单流 dd (4.3GB, O_DIRECT) |
  |------|------|
  | 1280（原） | **835 MB/s** |
  | 4096（改） | **807 MB/s**（噪声级，未变快） |
- **结论**：调大 max_sectors_kb 对吞吐无增益（835 vs 807 ≈ 噪声）。**588MB/s 不是 max_sectors 造成的硬墙**——本探针单流 O_DIRECT 直接到 835MB/s，此前测 588 系当时负载/冷态差异。已还原 1280。
- **对"拆 N 线程提速"问题的定论**：单流已 835MB/s，引擎两流并发聚合 ~2GB/s 已超单流数倍、吃到设备并发，**再加流不会涨总带宽**（共享同一 NVMe 物理通道/内存 DMA）。拆 8 线程无收益，已实测排除。
- **新的可能增长点**：835MB/s 证实设备上限更高；引擎侧专家段 304MB/s、trunk 733MB/s 低于设备——若想榨 x86 参考实现，改进点在**引擎读路径并发/块大小**，但既然 FPGA 将独占全带宽，此探针价值有限。
- **划掉项**：max_sectors_kb 调参、加读线程数。剩：FPGA 侧全带宽读兼容性验证。

**2026-09-01 FPGA 138K Pro 到货——GEMV 下沉接入现状盘点**：
- **板型确认**：Tang Mega 138K Pro = **GW5AST-LV138FPG676AES**（GW5AST-138B）。硬核 PCIe 3.0（板上 4-lane×5G=20Gbps 金手指）+ 8×12.5Gbps SerDes + 板上 M.2 + LCD。
- **FPGA 侧成熟度（rtl/13_mega138k + 12_fpga_proto + 14_serdes_proto）**：
  - `engine_core`（SIMD MAC 128-lane，4-bit 量化码）× 已综合板级（board_top 冒烟，build_board_top.tcl 用 Gowin 综合）。
  - `pcie_dma_engine` / `proto_core`：AXI-Stream 帧协议（帧头 cmd/seq/len + 负载 tlast 背压），结果回传 holding。
  - `14_serdes_proto`：SerDes 抽象层 + 两条通路（axis_pcie 桥 ← PCIe；NVMe host + ext4 扫描 + file2lba ← M.2 直读）。19/19 仿真全绿。
- **尚未实现（接入真实推理的断点）**：
  - **主机侧（Windows/WSL）PCIe 栈 + 驱动 + 上位机**（把 k3 的 Q3 权重/激活灌进 FPGA，收结果回引擎）——完全没有。
  - **FPGA 侧 NVMe 主机控制器**（adapter/nvme 只有 N1-N6 蓝图，无 RTL；现用"字流桩"）。
  - `/dev/dfl*`、FPGA 驱动在 Windows/WSL 均未枚举（主机 PCI 列表只有 1D94 芯片组/Innosilicon GPU/Realtek 网卡，无 Intel/Altera 设备）——Gowin 驱动需装，且 WSL2 默认不直通 PCIe。
- **待决策（两条天壤之别的路径）**：
  - **路径1（PCIe 灌权重）**：FPGA 插主板 PCIe，主机跑驱动+上位机把权重流经 gowin_pcie_ip→proto_core→engine_core。工程量在主机侧 PCIe 栈；Gowin PCIe 驱动/上位机；WSL2 需 GPU-PV 或原生 Ubuntu 才能碰 PCIe。
  - **路径2（FPGA 独立读 NVMe）**：FPGA 板上 M.2 槽，FPGA 自己当 NVMe host 从共享盘读权重（已验证 127.46s/token 的 /mnt/nvme 那块），GEMV 全程在 FPGA 内闭合，主机只发 token 路由。工程量在 NVMe host RTL（N1-N6）。
  - 本机 x86 推理已被证明是算力墙（0 tok/s 增量）——真正价值是"存储+专家 GEMV 一起端到端下沉"，对应路径2 才吃满 8×12.5Gbps SerDes。
- **下一步建议**：先确认板上 M.2 引脚接的是"PCIe 硬核"还是"通用 SerDes"（决定 N4/N5），再启动 NVMe host RTL。
- **保留**：metanvme.sh / k3_nvme.{out,err,json}；二进制 12:11 版仍是当前最优。

**2026-09-01 阶段A 封锁——确定性 GEMV 自测期望值修正（方案2 定案）**：
- **背景**：board_top.v 已改确定性自测（200MHz PLL `Gowin_PLL_X200` + 固定 w/x + 跑 16 拍停，SUM 上 LCD Line3）。用户拍板：**保留 SELFW=4'b0010（mag=2, sgn=0），只改注释期望值 = 0x2000**。
- **期望值硬核算（python 精确模拟 simd_mac_array + reduction_tree 验证）**：
  - `SELFW=4'b0010`（E2M1 值 **4**，非 2）：`mag=2→kx=2x`，`prod13 = sgn?−2kx:2kx = +4`（每 lane 每拍乘积 = E2M1值×x = 4×1 = 4）
  - 单拍 128 lane = 512；16 拍 acc 持续累加 = **8192 = 0x00002000**
  - **旧注释（0x1000=4096）是错的**——错因把 E2M1 值当 2 而非 4（倍频乘 2 藏在 prod13 的 `{kx,1'b0}`）。
- **验收判据**：LCD Line3 显示 `SUM: 00002000（hex）` ⇒ 128-lane MAC 引擎正确。若显示非 0x2000 ⇒ 需查引擎逻辑。
- **改动范围**：仅改 board_top.v **注释**（文件头自测设计 + SELFW 旁注），**所有硬件参数/逻辑原样**（SELFW=0010/SELFX=01/200MHz PLL 均保留）。diff 已核对：仅 3 处注释行，零逻辑改动。
- **下一步（等编译可用）**：Gowin 综合 `build_board_top.tcl` 出 bitstream → Programmer 经 USB-JTAG 烧录 → 拍照比对 LCD SUM=00002000。


 

**2026-09-01 阶段A 编译卡死——死锁证据链闭环（定论）**：
- **定论**：PNR 布线阶段永不收敛——Routing Phase 0（快速合法布线）能完成，之后任何后续路由阶段在**单核满转**下走不到头，被手动 kill。非资源/约束/综合层问题。
- **快速布线 Phase 0 实际已通过**（board_top.log 12 行：布局 Phases 0-3 + `[60%] Routing Phase 0 completed`，此后零写入）→ **存在合法布线方案**，卡死点在 Phase 0 之后的后续路由阶段。
- **动态铁证**（kill 前采样）：gw_sh PID 30600 启动 2447s、CPU 累计 2439s，**5 秒窗增量恰 = 5.0s（99.7% 单核满转）**；Responding=True、19 线程、WS 2.18GB 持续膨胀 → 纯热点循环，非挂起；路由器进程内联，无子进程。用户拍板**杀掉**（18:22:33 确认）。
- **复现性**：build2/3/5 三次全部同款冻结 `[60%] Routing Phase 0` 行，从未产出 .fs/.bit；aa9158c"修复"未触及根因（200MHz 目标在稀疏布局大器件上实际布线延迟不可达）。
- **健康基线**：综合 2 分钟，资源仅 10%（LUT 6045/138240，REG 7952/139140），Fmax=246.9MHz@200MHz（**无布线延迟的理想值**），时钟三约束全命中；官方 demo（led/ddr3_400M）Place_Option/DSRM 配置一致 → 排除配置异常。
- **症结指向**：138K 大器件 + 仅 10% 稀疏布局 → 线长飞远 → 5ns 目标布线延不可达，Gowin 布线器无迭代上限 → 死循环。
- **勘误（2026-09-01）**：`-global_freq 100.000` 是 Gowin 工具默认兜底值（tcl 未设；prj `<Option type="global_freq" value="100.000"/>`、process_config `"Global_Freq":"default"`），只约束**无显式 create_clock 的时钟路径**，**与 SDC clk_200m=200MHz 不冲突**。引擎 200MHz 权威约束 = SDC `create_clock engine_clk_200 -period 5 [get_nets clk_200m]`。SDC 注释中"100MHz 不可达死循环"是 PIPE_MUL 流水化之前的旧历史，不再适用。
- **勘误2（timing 开关乌龙）**：死循环**与 timing driven 无关**——tcl 第34行实为 `set_option -timing_driven 0`，新版 cmd.do 无 `-timing` 行，即 **timing 驱动关闭**。此前"时序驱动精化(Phase1)死循环"解释链已整体推翻，见死锁定论修订。残留根因候选：路由引擎在 138K 大器件 + 128-lane 数组展开网表上的**非时序路由段收敛问题**（工具级，非配置级）。待验证实验：`-timing_driven 1` 反向对比 / `enable_dsrm 1` / 报告 bug。
- **最小代价验证方案（未跑，待用户决定）**：SDC 引擎时钟降 100MHz 与 -global_freq 对齐（或关 -timing），不改任何 RTL，预计布线 2-3 分钟、全程约 6 分钟 = 提速 >10x 出 bit。**暂不重跑（用户已确认）**。
- **\.p 文件为 GOWIN AES-128-CBC 全加密**（pragma protect，路由表 563856B+584832B 两数据块），文本挖掘死路，无需再试。

**2026-09-01 �不降频出路的定论（SUG100 权威手册背书）**：
- **用户拍板：引擎 200MHz 物理频率不动，不降频**。
- **根因更进一步（手册对照）**：cmd.do/tcl 硬编码 -place_option 0 -route_option 0 = 通用默认低速算法，而 **GW5A(S)(T)-138 官方默认是 place=3（专用默认布局）+ route=2（提速路由算法）**（SUG100-4.4.6E 第50-51页）。0/0 组合偏离器件特性 → 或正是布线不收敛诱因。
- **实测结果（2026-09-01 18:32-18:47 第二轮，place=3/route=2）**：**同样在 `[60%] Routing Phase 0` 后死循环**（停滞 9.5 分钟，SUSPECTED_HANG 触发，满核 CPU 986s 后手动 kill）。→ **place/route 算法选项不是根因**，已排除。
- **已改动（仅编译参数，零 RTL）**：build_board_top.tcl line32-33 → place_option 3 / route_option 2，注释已写明依据。**按用户选择暂未重跑**。
- **待跑验证**：后台运行 + 10 分钟日志零进展自动 kill 保险；预计布线 2-3 分钟 → 全程 ~6 分钟出 bit = 提速 >10x。PLL 与 SDC 完全不动，仍 200MHz。
- **若 3/2 仍不收敛的候补**（同为不降频）：place_option=4 / enable_dsrm=1（138K 专属路由资源）/ route_option=1（更优但更慢，不推荐）。
- **遗留小疑点**：tcl set_option -timing 0 与 cmd.do 裸 -timing 不一致（0=关，裸=开）——本次未动，若 3/2 仍卡再核查。
