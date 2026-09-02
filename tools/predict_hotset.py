#!/usr/bin/env python3
"""predict_hotset.py — 每层衰减热表（Tier-3 历史预测）的实证切片

问题：在 run 开始前，用"该层的历史频率表（带衰减）"取 top-K 当预测集，
      能覆盖本 run 实际需要的多少个不同专家？

覆盖率 = |预测集 ∩ 本run专家集| / |本run专家集|

对照系：
  γ=1.0   纯累计（不衰减，旧历史和新历史一样重）
  γ=0.9/0.8/0.5   衰减（越近的历史越重）
  prev-run  上一轮该层的专家集（无表、只看上一次）
  oracle   本 run 真实集（上限，100%）
  random   均匀随机取 K 个（无信号地板 = K/896）

用法：python3 predict_hotset.py
"""
import struct
import collections

PATH = "/mnt/f/sram/sram/data/expert_trace.bin"
N_EXPERTS = 896
KBYTES = 17_547_264


def load(path):
    raw = open(path, "rb").read()
    n = len(raw) // 8
    return [struct.unpack("<ii", raw[i * 8:i * 8 + 8]) for i in range(n)]


def group_runs(reqs):
    runs = []
    cur = [reqs[0]]
    for r in reqs[1:]:
        if r[0] == cur[0][0]:
            cur.append(r)
        else:
            runs.append(cur)
            cur = [r]
    runs.append(cur)
    return runs


def main():
    reqs = load(PATH)
    runs = group_runs(reqs)
    print(f"runs={len(runs)}  requests={len(reqs)}")
    print("super-iter 首 run 的层（验证按 super-iter×层 排列）:",
          [runs[s * 92][0][0] for s in range(8)])

    per_layer = collections.defaultdict(set)
    for L, e in reqs:
        per_layer[L].add(e)
    distincts = sorted(len(v) for v in per_layer.values())
    print(f"每层 distinct 专家数: median={distincts[len(distincts)//2]} "
          f"max={distincts[-1]} mean={sum(distincts)/len(distincts):.1f}")

    KS = [10, 20, 30, 50, 80, 130]
    GAMMAS = [1.0, 0.9, 0.8, 0.5]

    # 预计算：prev-run 与 oracle 与 random 与 top-K 静态（全历史累计）
    prev_set = {}          # layer -> last observed set
    oracle_by_K = {}
    rand_by_K = {}
    cum_by_K = {}          # γ=1 累计
    decayed = {g: {} for g in GAMMAS}

    # 按 (predictor, K) 独立跑，避免状态纠缠
    PREDICTORS = GAMMAS + ["prev", "prevK", "oracle", "rand"]
    results = {}

    for gamma in PREDICTORS:
        for K in KS:
            freq = collections.defaultdict(collections.Counter)
            prev = {}
            prev_counts = {}
            covs, warm = [], []
            rand_seed = 0

            for idx, run in enumerate(runs):
                L = run[0][0]
                S = {e for _, e in run}
                if gamma == "prev":
                    P = prev.get(L, set())
                elif gamma == "prevK":
                    P = set(x for x, _ in prev_counts.get(L, collections.Counter()).most_common(K))
                elif gamma == "oracle":
                    P = S
                elif gamma == "rand":
                    rand_seed += 1
                    import random
                    random.seed(rand_seed)
                    P = set(random.sample(range(N_EXPERTS), min(K, N_EXPERTS)))
                else:
                    P = set(x for x, _ in freq[L].most_common(K))
                if S:
                    c = len(P & S) / len(S)
                    covs.append(c)
                    if idx >= 92:
                        warm.append(c)
                # 更新
                if gamma != "oracle" and gamma != "rand":
                    if gamma == "prevK":
                        prev_counts[L] = collections.Counter(e for _, e in run)
                    elif gamma == "prev":
                        prev[L] = S
                    else:
                        if gamma != 1.0:
                            for x in list(freq[L]):
                                freq[L][x] *= gamma
                        for e in S:
                            freq[L][e] += 1

            allc = sum(covs) / len(covs) * 100
            warmc = sum(warm) / len(warm) * 100
            results[(gamma, K)] = (allc, warmc)

    # 输出：按 predictor 汇总
    print(f"\n{'predictor':<10}" + "".join(f"{'K='+str(k):>10}" for k in KS))
    for name, key in [("γ=1.0", 1.0), ("γ=0.9", 0.9), ("γ=0.8", 0.8),
                      ("γ=0.5", 0.5), ("prev-run", "prev"), ("prev-run-K", "prevK"),
                      ("oracle", "oracle"), ("random", "rand")]:
        row = f"{name:<10}"
        for K in KS:
            allc, warmc = results[(key, K)]
            row += f"{warmc:>9.1f}%"
        print(row)

    # 请求加权命中率（真实 BW 度量）：按请求条数算，γ=0.8 热表
    print("\n请求加权命中率（warm, γ=0.8 热表，按请求条数计）:")
    freq = collections.defaultdict(collections.Counter)
    row = "γ=0.8   "
    for K in KS:
        hits, tot = 0, 0
        for idx, run in enumerate(runs):
            L = run[0][0]
            S = {e for _, e in run}
            if idx >= 92:
                P = set(x for x, _ in freq[L].most_common(K))
                hits += sum(1 for _, e in run if e in P)
                tot += len(run)
            for x in list(freq[L]):
                freq[L][x] *= 0.8
            for e in S:
                freq[L][e] += 1
        row += f"{hits/tot*100:>9.1f}%"
    print(row)

    # K=30 的内存折算
    K = 30
    gb = K * len(per_layer) * KBYTES / 1e9
    print(f"\nK=30 × {len(per_layer)} 层 × {KBYTES/1e6:.1f}MB ≈ {gb:.1f} GB 的专家（对照全局 n50≈41GB）")

    warm = results[(0.8, 30)][1]
    print(f"γ=0.8 K=30 的热表覆盖率（warm）≈ {warm:.1f}% —— 即历史信号能预判本 run 约三成四的专家需求")

    # 验证：衰减是否真的改变 top-K 集合（γ 全相同可能是稳定热集，也可能是 bug）
    from collections import Counter
    f1 = collections.defaultdict(Counter)
    f5 = collections.defaultdict(Counter)
    differ = 0
    for idx, run in enumerate(runs):
        L = run[0][0]
        S = {e for _, e in run}
        if idx >= 92 and set(x for x, _ in f1[L].most_common(30)) != set(x for x, _ in f5[L].most_common(30)):
            differ += 1
        for x in list(f1[L]):
            f1[L][x] *= 1.0
            f5[L][x] *= 0.5
        for e in S:
            f1[L][e] += 1
            f5[L][e] += 1
    print(f"γ=0.5 vs γ=1.0 在 K=30 顶层预测集合发生分歧的 run 数: {differ}")


if __name__ == "__main__":
    main()
