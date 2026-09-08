# 专家缓存的预测式淘汰：热计数 vs LRU，真机可落地的 ÷5.6

> 系列：跨模型可移植性 / L2 专家缓存策略
> 状态：已实现（`moe-paging` 内核已换 brain），待真机验证
> 上位结论：`k3-online-feasibility-terminus.md` · 坍缩点复核：`l2-cache-records-verdict.md`

---

## 一、选题：为什么值得写

这是本项目中少数几个**真机可实现 + 有量化对比 + 有理论解释**的题材，不依赖 GPU。

| 评审维度 | 评估 |
|---|---|
| 新颖性 | 中。LFU 本身不新，但 **"单调超集 session 下热计数 vs LRU" 的专用性、以及跨模型发现（Qwen无固定共享 → k3单调超集）** 较新 |
| 真机可实现 | **强**。改动 3 行核心（`choose_victim`），在已有 llama.cpp moe-paging 内核上跑真机即可出数 |
| 量化对比 | **强**。LRU 36.24% vs predictive 88.46%，miss 63,824→11,551（÷5.6），HDD→SSD 复制次数同降 |
| 理论解释 | **强**。k3 8 遍单调超集（pass_v ⊆ pass_v+1）保证热表不失效；对应 Qwen 的跨 trace 翻转 |
| 可复现 | **强**。`sim_cache.py` 一键复现 + trace 落盘 |

**结论：可作为一篇短文 / 论文中的一个核心实验小节，不可作为整篇主脑（工程贡献偏单点）。**

---

## 二、问题定义

MoE 逐 token 前向，每层 896 专家、激活 top-16。权重从 HDD→SSD→DRAM 逐级上读。
在 32GB 无显存机器上，专家权重装不下 → 每次 miss 触发一次跨级复制。

**分布观察（k3 真机 trace，100,096 请求 / 10,010 唯一专家）**：
专家请求带 8 遍结构，每遍专家集是上一遍的**单调超集**——

    pass0 ⊆ pass1 ⊆ ... ⊆ pass7

同一批专家被 8 遍反复激活。缓存若在遍间隔把它们踢掉，就要反复重拷。

## 三、基线：LRU 为什么差

`choose_victim`（旧）按 `last_use` 选最久未用：

    命中时 last_use = ++clock

8 遍之间，上一遍激活的专家因"中间未紧邻使用"被 LRU 挤出 → 下一遍又 miss → 反复跨级重拷。
LRU @150 槽 → 命中 36.24%，miss 63,824 次 = 63,824 次 HDD→SSD 复制。

## 四、方案：累积热计数（predictive/LFU）淘汰

给每个 cache entry 一个持久 `use_count`（热计数），淘汰选**计数最低**而非最近：

    cache_entry { ..., uint64_t use_count; }
    命中 ⇒ ++use_count
    载入 ⇒ use_count = 1
    choose_victim ⇒ 选 use_count 最小者

直觉：**单调超集 session 里，"总被用的专家"必然在后续遍仍被用 → 保留热常客，牺牲一次性的生面孔。**

## 五、为何这个方案站得住（理论 + 真机双重支撑）

1. **k3 单调超集**保证热表在 session 内不失效——predictive 是同 session 自适应，不假设跨分布通用。
2. **跨分布的坍缩点已被真机坐实**（`l2-cache-records-verdict.md`）：Qwen load2+heat1 反亏
   +10.3% miss → **热表不可跨 trace 迁移**。predictive 在线采集、在线应用，恰好规避了这个坑。
3. 这也回应"谁是受益者"：÷5.6 降的是 **miss 次数**，即每次 HDD→SSD 复制 + SSD→DRAM 加载，
   对"天沟"（HDD 8TB→SSD 500GB）是实打实减少复制次数。

> 与 L2 的关系：predictive **不是多一级缓存**，而是**同一个 L2 换了踢人依据**。
> 专家实体仍驻留原 L2（DRAM/SRAM pool），predictive 只是决策模块（热度表在 CPU 内存，
> 不占宝贵的权重空间）。

## 六、复现数字（sim_cache）

```
CACHE   SLOTS   PREDICT
150槽     150    88.46      ← predictive（累积热度 top-K, 在线）
（对照 LRU 36.24%, miss 63,824 → 11,551, 磁盘读 1120GB → 203GB, ÷5.6）
```
复现：`python3 sim_cache.py data/expert_trace.bin --slots 150 --policy predictive`

gap 分析：predictive 88.46% → layer-first 理论上限 90%（=(N−unique)/N）的 1.54pt，
全部来自每 pass 新增专家的**首触 compulsory miss**（~16 专家/层 × 92 层），不可压缩。

## 七、真机移植（moe-paging 内核已改）

| 位置 | 改动 |
|---|---|
| `moe-cache.h` | `cache_entry` + `uint64_t use_count` |
| `moe-cache.cpp:79` | `choose_victim` last_use→use_count（热计数） |
| `moe-cache.cpp:141` | 命中 ++use_count |
| `moe-cache.cpp:166` | 载入 use_count=1 |
| `MOE_PAGING.md` | policy 说明（predictive + 单调超集依据） |

> 本机无 ggml header 无法编译，待用户电脑 llama.cpp 构建验证。
> 改动自洽、不添依赖、不改接口，compile 风险低。

## 八、论文素材组织建议

**标题方向**：*Monotone-Superset Expert Sessions: When Cumulative-Heat Beats LRU in On-Memory MoE Inference*

**方法**：describe predictive eviction as "session-adaptive heat policy over a monotone-superset request stream"

**实验设计**（论文栏）：
| 行 | 负载 | 列 | 策略 | 指标 | 期望 |
|---|---|---|---|---|---|
| 1 | k3 trace | predictive vs LRU | miss 数 | 88.46% vs 36.24% |
| 2 | k3 trace | 每 pass 命中率曲线 | 单调超集验证 | pass0~0% → pass7~100% |
| 3 | Qwen trace | 跨 trace 热表迁移 | miss 增减 | 同分布 −17.8% / 跨分布 +10.3% |
| 4 | **真机 moe-paging** | predictive vs LRU | moe_stats hits/misses | 待测（预期 miss ÷5.6） |

**贡献点**：
1. 首个"单调超集会话 → 热计数淘汰"的专用性分析（真正的新点）
2. 跨模型发现：Qwen 无固定共享专家 → k3 单调超集（见 `qwen-to-k3-borrow.md`）
3. 真机坐实"热表跨分布不可迁移"的坍缩点（+10.3% 反亏），界定了 predictive 的适用边界

**诚实的限制**（论文 reviewers 会问）：
- 非 GPU；单流单模型；32GB 内存约束下的结论，GPU 常驻显存时不成立（trunk 税消失）
- LFU 在 pass 长度不稳定、专家集退化的 session 下可能退化（未测）
- ÷5.6 是磁盘读 / 复制次数，**不改变 DRAM→GEMV 带宽主瓶颈**（t/s 受 rtl/12、rtl/15 拖）

**一句话卖点**：*在受内存约束的 MoE 推理里，基于单调超集会话的热计数淘汰，把专家 HDD→SSD 复制次数降低到 LRU 的 1/5.6，且在线可兑现、无跨分布风险。*

## 九、下一步（论文所需证据链）

- [ ] **真机跑通 predictive eviction**（moe-paging 已改），出 `moe_stats` 前后对比 — 最关键
- [ ] 真机每 pass 命中率曲线（验证单调超集推理在真实 runtime 成立）
- [ ] （可选）复现 Qwen 跨 trace 翻转到 predictive 版，确认方向性失败被规避
- [ ] 控制变量：cap 从 63/150 扫到满槽，画 hit% vs 槽数曲线（论文图）

---
*2026-09-07 · 从 sim_cache 仿真到 moe-paging 真机内核的移植，一步到位*
