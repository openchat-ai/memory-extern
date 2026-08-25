#!/usr/bin/env python3
"""
hot_expert_cache_sim.py — 热专家缓存命中率模拟器（§12.2 前置验证）

目的：在上板之前，用访问轨迹模拟回答一个问题——
      "1GB DDR3 缓存热专家，到底能省多少 SerDes 带宽？"

模型假设（K3 形状）：
  层数 L=64，每层专家数 E=8（top-k=2 激活）
  全模型 mxfp4 约 15GB，均匀切到 L×E 个对象
  对象粒度 = 一个"层×专家"切片（预取/缓存的最小单元）

策略：
  LRU / LFU / 预测式（按历史频率直接排序，理想化上界）

用法：
  python3 hot_expert_cache_sim.py                # 默认轨迹 10^6 步
  python3 hot_expert_cache_sim.py --zipf 1.5     # 更尖的重尾
"""

import argparse
import random
from collections import OrderedDict


class LRUCache:
    def __init__(self, cap_objects):
        self.cap = cap_objects
        self.od = OrderedDict()

    def access(self, key):
        if key in self.od:
            self.od.move_to_end(key)
            return True
        if len(self.od) >= self.cap:
            self.od.popitem(last=False)
        self.od[key] = 1
        return False


class LFUCache:
    def __init__(self, cap_objects):
        self.cap = cap_objects
        self.freq = {}          # key -> count
        self.tick = 0
        self.items = {}         # key -> (last_tick)

    def access(self, key):
        self.tick += 1
        hit = key in self.freq
        if hit:
            self.freq[key] += 1
        else:
            if len(self.freq) >= self.cap:
                victim = min(self.freq,
                             key=lambda k: (self.freq[k], self.items[k]))
                del self.freq[victim]
                del self.items[victim]
            self.freq[key] = 1
        self.items[key] = self.tick
        return hit


def gen_trace(n_steps, n_layers, n_experts, topk, zipf_s, seed):
    """每步：随机一层 + 该层按 Zipf 抽 topk 个专家"""
    rng = random.Random(seed)
    # 预生成每个专家的 Zipf 权重
    w = [1.0 / (i + 1) ** zipf_s for i in range(n_experts)]
    cum = []
    t = 0.0
    for x in w:
        t += x
        cum.append(t)
    total = cum[-1]

    def pick():
        r = rng.random() * total
        for i, c in enumerate(cum):
            if r <= c:
                return i
        return n_experts - 1

    trace = []
    for _ in range(n_steps):
        layer = rng.randrange(n_layers)
        chosen = set()
        while len(chosen) < topk:
            chosen.add(pick())
        for e in chosen:
            trace.append((layer, e))
    return trace


def run(trace, cache_objs, obj_mb):
    lru = LRUCache(cache_objs)
    hits_lru = 0
    for k in trace:
        hits_lru += lru.access(k)
    return hits_lru / len(trace)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--steps", type=int, default=200_000)
    ap.add_argument("--layers", type=int, default=64)
    ap.add_argument("--experts", type=int, default=8)
    ap.add_argument("--topk", type=int, default=2)
    ap.add_argument("--zipf", type=float, default=1.2)
    ap.add_argument("--model-gb", type=float, default=15.0)
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    total_objects = args.layers * args.experts
    obj_mb = args.model_gb * 1024 / total_objects
    trace = gen_trace(args.steps, args.layers, args.experts,
                      args.topk, args.zipf, args.seed)

    print(f"轨迹长度     : {len(trace):,} 次对象访问")
    print(f"对象总数     : {total_objects}（{args.layers}L×{args.experts}E）"
          f"，每片 {obj_mb:.0f} MB")
    print(f"Zipf 偏斜 s  : {args.zipf}\n")

    print(f"{'DDR3 预算':>10} {'可容对象':>8} {'LRU 命中率':>10}"
          f" {'SerDes 节省':>12}")
    print("-" * 46)
    for gb in (0.25, 0.5, 1.0):
        cap = int(gb * 1024 / obj_mb)
        h = run(trace, cap, obj_mb)
        print(f"{gb:>8.2f} GB {cap:>8} {h:>9.1%} {h:>11.1%}")

    print("""
解读：
  命中率 h ⇒ 有效带宽放大 1/(1-h)，直到撞算力墙(63t/s)。
  若 1GB 命中 ≥80%，批量吞吐即从 50 → 250 t/s 上限兑现。
""")


if __name__ == "__main__":
    main()
