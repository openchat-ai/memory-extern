# moe-paging 仿真复现 + 单调超集真机 trace 独立验证

日期: 2026-09-08
数据: `data/expert_trace.bin` (800KB, 100,096 请求, 10,010 唯一专家, int32 对: (layer<<20)|expert)
工具: `sim_cache.py`（本 repo）；独立验证脚本 `trace_monotone.py`

## 一、sim_cache 全槽数梯度（可复现, 纯标准库）

命令: `python3 sim_cache.py data/expert_trace.bin --slots 63,100,150,200,300,500,896`

compulsory 上限 = (N−unique)/N = 89.9996%

### order=trace（原始顺序, = 上游 sim_cache）

| 槽 | LRU | BELADY | PIN+LRU | PREDICT | MISS | GB |
|---|---|---|---|---|---|---|
| 63 | 35.57 | 36.58 | 33.02 | **70.88** | 64491 | 1131.6 |
| 100 | 36.14 | 36.88 | 35.38 | **87.33** | 63918 | 1121.6 |
| **150** | 36.24 | 37.28 | 36.38 | **88.46** | 63824 | 1119.9 |
| 200 | 36.24 | 37.64 | 36.85 | 88.46 | 63824 | 1119.9 |
| 300/500/896 | 36.24 | 38.34~42.5 | 37.29~39.4 | 88.46 | 63824 | 1119.9 |

关键: predictive 150 槽 88.46% 已到其自身上限（每层只预取 top-150）, 加槽不提升。
LRU 恒 36.24%（>63 槽饱和）→ 笔记"LRU 结构性平台"坐实。

### order=layer-first（同层聚合）

| 槽 | LRU | BELADY | PIN+LRU | PREDICT |
|---|---|---|---|---|
| 150 | **90.00** | 90.00 | 56.67 | 1.37 |

LRU layer-first 150 槽直达 90% 理论上限（离线手段）。predictive layer-first=1.37%
（其语义是"每层切换时预取历史 top-k", layer-first 下每层只出现一次, 无历史积累 → 失效）——
印证 predictive 是**在线同 session 自适应**, 只在原始 8 遍顺序下有效。

## 二、单调超集独立验证（trace 直读, 非 sim 推断）

命令: `python3 trace_monotone.py`（将脚本入 notes 或 tools 以可复现）

- 结构: 92 层 × 8 pass = 736 连续同层块; 每层恰好 8 遍装载。
- **pass_i ⊆ pass_{i+1} 严格成立: 92/92 层, 无一违反。**
- 每 pass 新增专家 1~15, 专家集 74→150 (L1 实例) 单调递增。
- 每 pass 对前 pass 累计并集命中率: L1 90.2→93.3%, L3 89.2→95.2%, L5 86.3→94.9%,
  随 pass 递增爬升 —— 与 predictive 的逐层热度积累机制吻合。

## 三、对 paper 的意义

1. **单调超集是 trace 的客观属性**（92/92 层验证）→ "predictive 天然同分布"的结构性保证
   从推断升级为独立复现证据。
2. sim_cache 数字与论文笔记完全一致（88.46 vs 36.24 → miss ÷5.55）可复现。
3. layer-first 90% 是离线上限, predictive 88.46% 是在线实用极限 —— 两者定位清晰。

## 四、未做（需真机 llama.cpp）

- moe-paging 内核的 `moe_stats` 前后对比（predictive vs LRU）——本机无 ggml header,
  需在用户电脑 llama.cpp build 跑。NOTES: `predictive-eviction-paper.md` §七 已列改动点。

## 复现脚本

- `tools/` 可收纳: `sim_cache.py`（repo 已有, 根目录）+ `trace_monotone.py`（临时目录）