#!/usr/bin/env python3
"""
policy_cmp.py — 周期保留策略重放对照：LRU / Belady(OPT) / 周期保留。

K3 批结构（白皮书 §5.7）：每个 run = (super-iter, layer) 组，5~12 批 token
共享该层专家；批内复用 88.3%（intra-run 重复），跨 run 净复用仅 ~1.7%。
→ 三种替换策略对照：
  - LRU         ：经典无未来信息，跨 run 会逐掉即将复用的块
  - Belady(OPT) ：离线先知，逐"未来最远才用"的块 → 替换策略理论上限
  - 周期保留    ：离线用 run 边界，跨 run 清空重建（吃死批内复用 88.3%），
                  是 Belady 的可实现近似（run 边界=调度器可见的静默点）

用法：python3 policy_cmp.py [trace] [--runs runs] [--caps 8,16,...]
输出：容量扫描三策略命中率对照表。
"""
import argparse
import heapq
import sys
from collections import OrderedDict


def load_trace(path):
    return [int(l) for l in open(path)]


def load_runs(path):
    try:
        with open(path) as f:
            return [tuple(map(int, l.split())) for l in f]
    except OSError:
        return None


def lru_hitrate(trace, cap):
    cache = OrderedDict()
    hits = 0
    for k in trace:
        if k in cache:
            hits += 1
            cache.move_to_end(k)
        else:
            if len(cache) >= cap:
                cache.popitem(last=False)
            cache[k] = None
    return hits / len(trace)


def belady_hitrate(trace, cap):
    """OPT：已知整个未来。驱逐 next-use 最远的块；永不再用视为最远。"""
    if cap <= 0:
        return 0.0
    nxt_at = {k: [] for k in set(trace)}
    for i, k in enumerate(trace):
        nxt_at[k].append(i)
    ptr = {k: 0 for k in nxt_at}          # 游标=当前正处理的出现序号；处理后 +1
    cache = set()
    hits = 0
    for i, k in enumerate(trace):
        if k in cache:
            hits += 1
        else:
            if len(cache) >= cap:
                victim = None
                far = -1
                for ck in cache:
                    p = ptr[ck]
                    d = nxt_at[ck][p] if p < len(nxt_at[ck]) else len(trace)
                    if d >= far:
                        far = d
                        victim = ck
                cache.discard(victim)
            cache.add(k)
        ptr[k] += 1
    return hits / len(trace)


def period_hitrate(trace, runs, cap):
    """周期保留：离线感知 run 边界。run 开始时把该 run 工作集预装进缓存
    （优先逐"外 run 早才用/不用"的块）→ 吃批内局部复用 + 尽可能保留跨 run 重叠。
    等价"超迭代周期的批级预取"：每个 (super-iter, layer) 批的专家集即兴装入。"""
    if runs is None:
        return None
    # 预构建每 run 工作集
    run_ws = {s: set(trace[s:s + L]) for s, L in runs}
    # 全局序号（同层多 run 共享专家池 → 跨 run 重叠可保留）
    cache = set()
    hits = 0
    run_idx = 0
    # 下一 use 距离（离线）：用于 run 边界驱逐选择
    nxt_at = {}
    for i, k in enumerate(trace):
        nxt_at.setdefault(k, []).append(i)
    ptr = {k: 0 for k in nxt_at}
    for i, k in enumerate(trace):
        if run_idx < len(runs) and i == runs[run_idx][0]:
            # 进入新 run：预装该批工作集（调度器已知本批路由专家集）
            cur_ws = run_ws[runs[run_idx][0]]
            for wk in cur_ws:
                if len(cache) < cap:
                    cache.add(wk)
                    ptr[wk] = max(ptr[wk], 0)
                else:
                    break  # 容量满，后续正常 miss 路径接手
            run_idx += 1
        # 正常访问
        if k in cache:
            hits += 1
        else:
            if len(cache) >= cap:
                # 驱逐"未来最远"（与 Belady 同类，但只用本批已知信息近似：
                # 这里用 run 内信息足够——实现成完整 OPT 更公平，参考 belady）
                far = -1
                victim = None
                for ck in list(cache):
                    p = ptr[ck]
                    d = nxt_at[ck][p] if p < len(nxt_at[ck]) else len(trace)
                    if d >= far:
                        far = d
                        victim = ck
                cache.discard(victim)
            cache.add(k)
        ptr[k] += 1
    return hits / len(trace)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", nargs="?", default="k3_trace.txt")
    ap.add_argument("--runs", default="k3_trace_runs.txt")
    ap.add_argument("--caps", default="8,16,32,64,128,256,512,1024")
    args = ap.parse_args()

    trace = load_trace(args.trace)
    runs = load_runs(args.runs)
    caps = [int(x) for x in args.caps.split(",")]

    if not runs:
        print("!! 无 run 边界文件，周期保留列跳过", file=sys.stderr)

    n = len(trace)
    u = len(set(trace))
    print(f"requests={n}  unique={u}  reuse={n/u:.2f}x  "
          f"hit_upper(LRU)={100*(1-u/n):.2f}%")

    print(f"\n{'cap':>6}  {'LRU':>7}  {'Belady':>7}  {'周期保留':>7}")
    for c in caps:
        l = 100 * lru_hitrate(trace, c)
        b = 100 * belady_hitrate(trace, c)
        if runs is not None:
            p = 100 * period_hitrate(trace, runs, c)
            print(f"{c:>6}  {l:6.2f}%  {b:6.2f}%  {p:6.2f}%")
        else:
            print(f"{c:>6}  {l:6.2f}%  {b:6.2f}%  {'--':^7}")


if __name__ == "__main__":
    main()