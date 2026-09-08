# K3 heat vs LRU 淘汰策略：sim_cache 曲线 + 真机 A/B 复核

> 日期：2026-09-08
> 触发：给 `sim_cache.py` 补上 heat（predictive/LFU）列后，K3 专家 trace 上得到与论文预期
> **相反**的结果。本文档记录完整数据 + 与真机 A/B 的对照 + 结论修正。
> 相关：`notes/predictive-eviction-paper.md`（原论文观点，需按本文修正）

---

## 一、为什么补 heat 列

- `sim_cache.py` 原本只有 LRU / Belady / PIN+LRU，没有 heat（predictive）列。
- 论文核心卖点"predictive 88.46% vs LRU 36.24%（miss ÷5.6）"在代码里无 heat 实现，
  无法复现。
- 真机 A/B（heat @148槽 vs LRU @148槽，2 tokens）刚做完，需要一条 sim 曲线把
  真机观察外推到全容量，于是补上。

## 二、真机 A/B（2026-09-08，`--l2-policy heat/lru`，同 L2 文件）

| 指标 | heat | lru | 差异 |
|---|---|---|---|
| L2 hits | 147 (3.81%) | 0 (0.00%) | heat +147 |
| L2 misses | 3,708 | 3,950 | heat −242 |
| L2 read from sdd7 | 2.58 GB | 0.00 GB | |
| L2 written to sdd7 | 70.54 GB | 73.12 GB | |
| 总时长 | 1391.7s | 1427.6s | heat 快 35.9s (2.5%) |
| s/token | 695.84 | 713.82 | heat 快 ~18s |

- **两跑共用 `exp_policy.l2`**：heat 先跑写入 148 专家，LRU 后跑 crc 校验通过、直接
  沿用该文件。所以 LRU 组拿到的是 heat 的热表残留。
- 结论：真机（2 tokens、1 pass+、持久化 L2）上 heat 可复现地优于 LRU。

## 三、sim_cache 曲线（`sim_cache.py` 加 heat 列后，K3 trace：100,096 请求 / 10,010 专家 / 90% 复用）

```
CACHE    SLOTS    LRU     HEAT   BELADY  PIN+LRU
2.6 GB    148    36.24%   3.28%   37.26%   36.36%
4.6 GB    262    36.24%   5.93%   38.07%   37.14%
8.0 GB    455    36.24%  10.29%   39.42%   37.82%
16.0 GB   911    36.24%  21.02%   42.61%   39.42%
32.0 GB  1823    36.24%  38.54%   48.99%   42.57%
64.0 GB  3647    36.24%  52.65%   61.74%   48.66%
128.0 GB 7294    49.19%  82.50%   84.59%   62.86%
192.0 GB10941    90.00%  90.00%   90.00%   90.00%
256+ GB           90.00%  90.00%   90.00%   90.00%
```

- **小容量（≤32GB）LRU 恒压 heat**：2.6GB/148槽，LRU 36.24% vs heat 3.28%（11 倍差）。
- **中容量（64-128GB）heat 反超 LRU**：128GB 槽，heat 82.50% vs LRU 49.19%。
- **≥192GB 全部顶到 compulsory 上限 90%**（10,010 全装下后策略无关）。

## 四、为什么和论文预期相反（核心发现）

1. **LFU 语义在"单调超集"K3 trace 上退化**：
   heat 把 count 高的老常客锁在槽里。但 K3 的 8 遍 pass 是集合层面的超集
   （pass_v ⊆ pass_{v+1}），**个体专家会退役**——第一遍的热门专家后面几遍不再用，
   却因 count 高霸占槽位，后 pass 的新专家进不来 → 命中率崩。
   这正是 `predictive-eviction-paper.md:115` 诚实限制"LFU 在 pass 长度不稳定、
   专家集退化的 session 下可能退化（未测）"——**现在测到了：K3 上确实退化**。
2. **LRU 在小容量反而好**：recency 语义天然适配"新 pass 的专家是刚用过的"，
   旧 pass 的退役专家自动被挤出，槽位留给当前活跃专家。
3. **真机 A/B 与 sim 不矛盾**：两者测不同场景——
   - 真机：2 tokens、1 遍半、L2 持久化热表残留 → heat 赢（残留正好是第二遍要用的）
   - sim：100,096 请求、8 遍完整超集、冷启动 → LRU 赢（LFU 锁死退役常客）
4. **论文卖点需修正**："predictive ÷5.6"在 K3 完整 trace 上**不成立**（LRU 反而赢 11x@2.6GB）。
   88.46% 那个数字是旧版在别的 trace/口径下得到的，当前 K3 trace 无法复现。

## 五、对工程的意义

- **K3 的 L2 用 LRU 更稳**：小容量（本机真实场景，~2.6-8GB）LRU 全面优于 heat。
- **heat 的价值只在"容量能装下持续活跃热区"时**（128GB 级），此时它逼近 Belady 上限
  （82.5% vs 84.6%），但 128GB 容量下 LRU 也有 49%——差距被容量本身吃掉大半。
- **engine `--l2-policy` 默认 heat 应改为默认 LRU**（或至少文档标注 heat 仅适用
  "同分布长会话 + 容量覆盖热区"）。真机那次 heat 赢是 L2 文件持久化带来的假象，
  不代表策略本身更优。

## 六、代码正确性验证（回应"heat 是不是写错了"）

- 质疑：heat 3.28% 低到可疑，是否 `sim_cache.py` 的 heat 实现有 bug。
- 验证：对照真机引擎 `k3_l2cache.c:174-176` 的 `l2_victim`——
  ```c
  uint32_t minc = l2->count[0];
  for (int i = 1; i < l2->nslot; i++)
      if (l2->count[i] < minc) { minc = l2->count[i]; best = i; }
  ```
  即"选 count 最小；ties 取最早分配的槽位 index"。sim 的 `heat` 用 `(count, seq)`
  元组（seq=分配序、命中不改）= 与真机**完全一致** → 3.28% 是 LFU 在 K3 trace 上的
  真实表现，非编码错误。
- 额外的发现：另一个 LFU 变体（count-bucket + 命中后移到更高桶末尾）在 148 槽给出
  11,007 hits（11%），优于原版 3,284（3.3%），但仍远低于 LRU 36.24%——即不管哪种
  LFU 变体，K3 上 heat 都打不过 LRU。结论稳健，不依赖 tie-break 细节。

## 七、复现

```
python3 tools/sim_cache.py tests/fixtures/expert_trace.bin
```

（tools/sim_cache.py 已加 heat 列，容量档含 2.6/4.6/8/16/32/64/128/192/256/384/512/768/1024/1450 GB）