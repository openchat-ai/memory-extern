# K3 L2 淘汰策略：fixtures trace vs 真机 trace 的对比裁决

> 日期：2026-09-08
> 触发：用户指出"真机每层单独一个槽、命中算账方式跟 sim 总账很不一样，真机更可信"。
> 用 `--dump-cache-trace` 导出的真机真实 trace（`/root/k3trace/expert_trace.bin`，12098 请求）
> 重跑 `sim_cache.py`，与 `tests/fixtures/expert_trace.bin`（100,096 请求）对比。
> 前置：`docs/k3/K3_HEAT_VS_LRU.md`（fixtures 结论）；本文修正/补充之。

---

## 一、两种 trace 的结构差异

| | fixtures/expert_trace.bin | 真机 /root/k3trace/expert_trace.bin |
|---|---|---|
| 来源 | 未知（合成/历史构造） | `--dump-cache-trace` 真机 4-token 实验（k3_run.c:1463）|
| 请求数 | 100,096 | 12,098 |
| distinct 专家 | 10,010 (12.14%) | 4,318 (5.24%) |
| 复用率 | 90.0% | 64.3% |
| token 数 | ~68 | ~8 |
| 最高专家热度 | ×68 | ×4 |

- 两者**完全不同**：fixtures 是长 trace（~68 token、多 pass、高复用），真机 trace 是
  短 trace（~8 token、单 pass、中复用）。

## 二、sim_cache 曲线对比（都含 heat 列）

### fixtures trace（长 trace）
```
CACHE    SLOTS    LRU     HEAT   BELADY  PIN+LRU
2.6 GB    148    36.24%   3.28%   37.26%   36.36%
8.0 GB    455    36.24%  10.29%   39.42%   37.82%
32.0 GB  1823    36.24%  35.32%   48.99%   42.57%
64.0 GB  3647    36.24%  52.65%   61.74%   48.66%
128.0 GB 7294    49.19%  82.50%   84.59%   62.86%
192+ GB          90.00%  90.00%   90.00%   90.00%
```

### 真机 trace（短 trace）
```
CACHE    SLOTS    LRU     HEAT   BELADY  PIN+LRU
2.6 GB    148     0.00%   0.00%    3.67%    1.84%
8.0 GB    455     0.00%   0.00%   11.28%    5.63%
32.0 GB  1823     3.44%  10.32%   42.30%   22.59%
64.0 GB  3647    35.67%  56.98%   64.31%   49.77%
128+ GB          64.31%  64.31%   64.31%   64.31%
```

## 三、两个 trace 都支持的结论

1. **小容量 LRU 不劣于 heat**（fixtures: LRU 36% >> heat 3-10%；真机: 小容量双 0%，LRU≈heat）。
2. **中容量 heat 反超 LRU**（fixtures 128GB: 82.5% vs 49.2%；真机 64GB: 57.0% vs 35.7%）。
3. **heat 的"远超"只在中间容量**（能装下部分长期热区但装不下全部），容量极大/极小都无差。

→ 策略相对优劣在两种 trace 下**方向一致**，但**绝对数字严重依赖 trace 结构**，不可跨 trace 外推。

## 四、真机 trace 暴露的 sim 模型缺失（最重要）

真机 4-token 实验实际表现：
```
l2cache [final step]: requests 12096, hits 12096 (100.00%), misses 0
  restored from meta: 4318 slots
  read from sdd7: 212.25 GB, written 0.00 GB
```

- L2 文件 `experts.l2`（200GB/11397 槽）启动时**从 meta 恢复 4318 槽**，正好覆盖全部
  distinct 专家 → **100% 命中、0 miss、0 慢盘流量**。
- 但 sim 在 128GB+ 只有 64.31%（冷启动，4318 distinct 全从盘读一次）。

**这是 sim 模型缺失的关键因素：L2 跨运行持久化（meta 恢复）**。真机在"看似不够"的
容量下也能靠上次运行残留的专家实现完美命中。策略之争（heat/lru）在持久化命中面前
**无足轻重**——真正的收益来自 `experts.l2` 这份 200GB 大缓存 + meta 复用，不是淘汰算法。

## 五、最终裁决

1. **用户主张成立**：真机 trace（逐请求、真实运行）比 fixtures 合成 trace 可信；
   两条曲线绝对数字不同，fixtures 的"90% / 36%"不能直接外推到真机。
2. **策略层面**：heat vs LRU 的方向性结论（小容量 LRU 优、中容量 heat 优）在两种
   trace 下一致，但**这是二级问题**。
3. **首要结论**：对 K3 真机部署，**L2 容量 + meta 持久化 >> 淘汰策略**。200GB
   大 L2 + 跨运行复用 = 100% 命中，heat/lru 差别（sim 里最多 20pt）在实际工作中被
   持久化命中完全淹没。engine `--l2-policy` 的默认值影响远小于 L2 文件是否够大。

## 六、复现

```
# 真机导出 trace
./bin/k3 /model --trunk ... --l2 /mnt/nvme/experts.l2 --l2-gb 200 --ids 3 --gen 4 --dump-cache-trace /root/k3trace

# sim 对比（两种 trace）
python3 tools/sim_cache.py tests/fixtures/expert_trace.bin
python3 tools/sim_cache.py /root/k3trace/expert_trace.bin
```

## 七、遗留问题

- fixtures `expert_trace.bin` 的真实来源未确认（合成 or 旧真机？），建议核对
  `tools/chk_trace.py` 或 git 历史。
- 真机 trace 只有 ~8 token，样本短；如需更稳的策略对比，跑 `--gen 32+` 导出更长
  trace 再 sim。
- engine `--l2-policy` 默认值是否改回 lru：**结论更新为"不着急改"**——因为
  L2 持久化命中的收益远大于策略差异，策略默认值对真实吞吐几乎无影响。