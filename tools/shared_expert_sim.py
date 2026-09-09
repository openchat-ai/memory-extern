#!/usr/bin/env python3
"""
shared_expert_sim.py — 离线"条件共享专家"仿真（无权重，纯 trace，专家 id 层面）

动机：kimi-k3 有训练出来的 shared_experts（固定共享专家，恒驻留，兜冷启动）。
我们无训练数据、无 Qwen 权重，无法合成真共享专家；但可以用真实路由 trace
在**专家 id 层面**回答一个等价问题：

  如果离线给每层预先选出一小批"常驻共享专家"，能否把 compulsory 地板
  （= 每层专家首次出现必触发的 miss）往下压？压多少？成本（resident 专家数/层）多少？

这实际上是把 kimi 的 shared_expert"概念"移植到 Qwen 的 trace 上做可行性上限。

策略对照（同预算、同 trace、逐位可比）：
  B  纯 LRU          —— 基线（上一版 8GiB=0.9396）
  C  静态热表 pin    —— top-K 全局贪心预压（已有档位 0.9963, C/B=1.06x 不过门）
  S  shared-preload —— 本文件核心：预压"首次出现最早的 K 个专家"，天然针对 compulsory

度量：
  命中率 / misses / compulsory-可避免比例 / resident 专家数（成本）

用法：
  python3 tools/shared_expert_sim.py                       # 用 trace-4
  python3 tools/shared_expert_sim.py --trace-2             # 用 trace-2 交叉
  python3 tools/shared_expert_sim.py --budget-mib 8192 --expert-mib 4
"""
import argparse
import json
import math
from collections import OrderedDict, Counter

BASE = "/data/data/com.termux/files/home/sram/data/traces"


def load_trace(path):
    """returns list of (layer, [expert...]) for decode segments only.
    Qwen trace-4: 前 3 段(prefill 16/256/64) 剔除, 取稳定 8-专家 decode 流."""
    dec = []
    with open(path) as f:
        for line in f:
            dec.append(json.loads(line))
    # 剔除 prefill 特殊段：只保留长度==8 的条目（= decode 活跃流）
    dec = [d for d in dec if len(d["experts"]) == 8]
    return dec


def first_touch_date(trace):
    """每个 (layer, expert) 首次出现的 token 序号（compulsory 来源）。
    返回 {(layer, exp): first_token_idx}"""
    ft = {}
    token = 0
    prev_layer = -1
    for d in trace:
        if d["layer"] < prev_layer:
            token += 1
        prev_layer = d["layer"]
        for e in d["experts"]:
            ft.setdefault((d["layer"], e), token)
    return ft, token + 1


def resident_cost(trace, per_layer_resident):
    """一个 (layer,exp) 常驻片 = 1 个对象；返回总对象数（成本度量）。"""
    return sum(len(v) for v in per_layer_resident.values())


def build_resident_trace_stat(trace):
    """用整段 trace 统计每层专家频率（= trace-统计学版"共享专家选取"，
    上界参考；真实在线只能用前缀，见 --no-oracle）。"""
    freq = Counter()
    for d in trace:
        for e in d["experts"]:
            freq[(d["layer"], e)] += 1
    return freq


def sim_pure_lru(trace, slots_per_layer):
    """B: 纯 LRU. slots_per_layer = 每层对象数预算."""
    caches = {}
    hits = 0
    tot = 0
    for d in trace:
        L = d["layer"]
        c = caches.setdefault(L, OrderedDict())
        for e in d["experts"]:
            tot += 1
            if e in c:
                c.move_to_end(e)
                hits += 1
            else:
                if len(c) >= slots_per_layer:
                    c.popitem(last=False)
                c[e] = 1
    return hits / tot, hits, tot


def sim_shared_preload(trace, resident, extra_lru_slots):
    """S: resident(常驻共享专家) + LRU(额外槽).
    resident = {(layer,exp)} 常驻(永不驱逐). resident 首触即命中(已预压)."""
    caches = {}
    hits = 0
    tot = 0
    for d in trace:
        L = d["layer"]
        c = caches.setdefault(L, OrderedDict())
        for e in d["experts"]:
            tot += 1
            if (L, e) in resident:
                hits += 1          # 纯 resident 命中, 不进 LRU
                continue
            if (L, e) in c:
                c.move_to_end(e)
                hits += 1
            else:
                if len(c) >= extra_lru_slots:
                    # 只驱逐"非resident"的 LRU 项
                    evict = None
                    for k in c:
                        if (L, k) not in resident:
                            evict = k
                            break
                    if evict is not None:
                        del c[evict]
                    elif len(c) >= extra_lru_slots:
                        pass  # 全是 resident, LRU 已满, 略过(理论不应发生)
                c[e] = 1
    return hits / tot, hits, tot


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default="trace-4")
    ap.add_argument("--budget-mib", type=int, default=8192)
    ap.add_argument("--expert-mib", type=float, default=4.0)
    ap.add_argument("--slots-sweep", type=int, nargs="+", default=[81])
    args = ap.parse_args()

    trace = load_trace(f"{BASE}/{args.trace}.jsonl")
    ft, ntokens = first_touch_date(trace)
    n_obj = len(ft)
    unique = {l: set() for l in set(d["layer"] for d in trace)}
    for (l, e) in ft:
        unique[l].add(e)

    print(f"== {args.trace} (decode 流) ==")
    print(f"  layer calls: {len(trace)}, tokens: {ntokens}, 专家首次触对象: {n_obj}")
    print(f"  每层 unique 专家均值: {sum(len(v) for v in unique.values())/len(unique):.1f}")
    print(f"  compulsory 对象总数: {n_obj}")
    # compulsory miss 物理地板(不计容量): 每个对象首次触必 miss
    comp_floor_touches = n_obj
    total_touches = sum(len(d["experts"]) for d in trace)
    print(f"  compulsory 地板(物理): {comp_floor_touches}/{total_touches} "
          f"= {comp_floor_touches/total_touches:.1%}")

    # 预算换算: 每层可用对象数
    budget_objs = int(args.budget_mib / args.expert_mib)
    per_layer_budget = budget_objs // len(unique)
    print(f"  预算 {args.budget_mib}MiB / {args.expert_mib}MiB = {budget_objs} 对象 "
          f"= {per_layer_budget} 槽/层\n")

    # ---- 预算公平对比: 总预算 T 槽/层, 分 resident R + LRU (T-R) ----
    print()
    print("== 预算公平对比 (总预算 = resident + LRU 槽/层) ==")
    print(f"{'T槽/层':>7} {'Rresident':>9} {'命中率S':>8} {'missesS':>8} "
          f"{'comp避免':>9} {'命中率B(LRU)':>11} {'Δpt':>6}")
    total_touches = sum(len(d["experts"]) for d in trace)

    def resident_by_firsttouch(trace, ft, per_layer_R):
        per_layer_ft = {}
        for (l, e), t in ft.items():
            per_layer_ft.setdefault(l, []).append((t, e))
        res = set()
        for l, arr in per_layer_ft.items():
            for t, e in sorted(arr)[:per_layer_R]:
                res.add((l, e))
        return res

    for T in args.slots_sweep:
        h_lru, hi_lru, _ = sim_pure_lru(trace, T)
        row = f"{T:>7} {'0':>9} {h_lru:>7.1%} {total_touches-hi_lru:>8}"
        row += f" {'0.0%':>9} {h_lru:>10.1%} {'—':>6}"
        print(row)  # 基线行(纯 LRU, R=0)
        for R in (int(T * x) for x in (0.25, 0.5, 0.75, 1.0)):
            if R < 1 or R > T:
                continue
            resident = resident_by_firsttouch(trace, ft, R)
            h_s, hi_s, _ = sim_shared_preload(trace, resident, T - R)
            avoided = len([x for x in resident if x in ft])
            print(f"{T:>7} {R:>9} {h_s:>7.1%} {total_touches-hi_s:>8} "
                  f"{avoided/total_touches:>8.1%} {h_lru:>10.1%} "
                  f"{(h_s-h_lru)*100:>+6.1f}")


if __name__ == "__main__":
    main()
