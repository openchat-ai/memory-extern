# SparkMoE MoE 专家分页调度 · 数据流图

> 源码：`moe-paging/`（约 1250 行，已逐行核验）。本文用 ASCII 图描述推理时一轮 decode 的数据流动。

## 总览（一图流）

```
                        ┌────────────────────────────────────────────┐
                        │            GGML 计算图（每层 MoE FFN）         │
                        │                                            │
┌─────────┐   token x   │  gate_inp ──MM──> logits ──softmax──> probs │
│ KV cache │──hidden───>│     │                       │              │
└─────────┘   h_t       │     │              argsort_top_k           │
                        │     │                       │              │
                        │     │              selected_experts        │
                        │     │                  (K 个专家 ID)        │
                        │     │                       │              │
                        │     │              ┌────────▼────────┐     │
                        │     │              │  remap_ids       │     │
                        │     │              │  (ggml_map_      │     │
                        │     │              │   custom1)       │     │
                        │     │              └────────┬────────┘     │
                        │     │              slot IDs  │              │
                        │     │                       ▼              │
                        │     │   mul_mat_id(gate/up/down 权重,      │
                        │     │              slot IDs)               │
                        │     └───────────────┬──────────────────────┘
                        │                     ▼
                        │              加权求和 → 下一层 h_{t+1}
                        └────────────────────────────────────────────┘
                                        ▲
              调度器（paging_manager / layer_cache）注入点：
              bind_pool 替换权重张量 + remap_ids 重写路由 ID

┌──────────────────────── 调度器内部 ────────────────────────┐
│                                                          │
│  model_index（只读索引，加载时建好）                         │
│   每个专家张量: name → {shard, file_offset, stride, type}  │
│        │                                                │
│        ▼                                                │
│  paging_manager ──按层懒创建──> layer_cache[每层独立]       │
│                                                          │
│  layer_cache（核心）                                      │
│    ┌────────────────────────────────────────────┐       │
│    │ slot 池（预分配 n_slots 帧，内存预算/每层）   │       │
│    │ entries[]: expert_id │ state │ last_use │  │       │
│    │   state ∈ {empty, loading, ready, error}      │       │
│    │   （in_use 由 active_refs 计数承担）           │       │
│    │ expert_to_slot[]: 专家→帧 反查表             │       │
│    └────────────────────┬───────────────────────┘       │
│                         │                              │
│   resolve(expert_ids)   ▼                              │
│   ① 去重 request_slots（同批重复专家只读一次）          │
│   ② 命中? ──是──> bump clock, active_refs++ ──> slot  │
│      │否                                              │
│      ▼                                                │
│   ③ choose_victim():                                  │
│       跳过 {pinned, active_refs≠0, loading}            │
│       ├─ 有空/error slot → 直接用                      │
│       └─ 否则 LRU: last_use 最小者被逐出               │
│      │                                                │
│      ▼                                                │
│   ④ 提交异步读: io_executor 线程池                     │
│       for 每个 miss × 每个张量(gate/up/down):          │
│         pread(fd, offset=file_offset+expert*stride,   │
│               dst=slot帧内存, len=stride)              │
│      │                                                │
│      ▼                                                │
│   ⑤ future.get() 全同步等待 ──> ready ──> 返回 slot ID │
│                                                      │
│   统计: hits/misses/evictions/bytes_read/latency      │
└──────────────────────────────────────────────────────────┘
```

## 存储层次与调度语义

| 层次 | 载体 | 谁在管 | 触发时机 |
|------|------|--------|----------|
| L0 计算缓冲 | GGML 激活张量 | 计算图 | 每 token |
| L1 专家缓存帧 | RAM slot 池（每层 n_slots） | layer_cache LRU | 每微批次 |
| L2 权重文件 | SSD GGUF | io_executor + pread | 缓存未命中时 |
| L3 索引 | RAM 元数据 | model_index | 加载时一次 |

## 关键不变量

1. `slots_per_layer >= 微批次唯一专家数`，由 `max_safe_ubatch = slots / K` 强制。
2. 帧布局 `nb[2] == 专家步长`，保证 pread 按专家切片与 GGML 视图一致。
3. 牺牲品不可驱逐 pinned / 在用 / 加载中的帧（`active_refs` 引用计数）。
4. 每层独立缓存，互不干扰（DSA/MLA 等注意力缓存同理，见 llama-kv-cache-*）。

## 时序（一次 decode 的一层）

```
t0   router 选出 K 个专家 ID（纯计算，无 I/O）
t1   resolve: 查命中 → 决定 miss 集
t2   I/O: miss 专家并行 pread（线程池, 通常 <1ms@NVMe, 5-20ms@磁盘）
t3   全部 .get() 汇合（同步屏障 —— 当前实现无跨 token 预取）
t4   mul_mat_id 计算（CPU 多线程）
t5   释放 active_refs → 帧回到可逐出状态
```

## 瓶颈热区（改进候选）

- **[同步屏障]** t3 完全阻塞，是内存-磁盘混合负载的最大痛点。
- **[无预取]** 时间维度专家相关性未被利用（anemll 有 `--moe-prefetch-temporal`）。
- **[LRU 无滞回]** 抖动态易 thrash（moe-autopilot 用 hot-list + 滞回，+26~31%）。
- **[无双缓冲]** 读下批时无法算上批。
