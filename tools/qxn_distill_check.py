#!/data/data/com.termux/files/usr/bin/python3
"""qxn_distill_check.py — 教师软目标质量诊断.

蒸馏成立的前提是**教师软目标确实携带信息**. 如果教师的软分布和硬标签
几乎一样 (温度太低 / 教师过度自信), 蒸馏退化为普通监督学习, 白做.

检查项:
  1. 教师 top-1 与真实 token 一致率      -> 教师是否可信
  2. 软目标熵 / 教师困惑度               -> 软目标携带多少信息
  3. top-1 概率分布                        -> 是否过度自信
  4. 软目标 vs 硬标签的 KL               -> 蒸馏相对 CE 的"额外信息量"
  5. 温度扫描下的熵                        -> T=2~4 是否合适
  6. Top-K 截断丢失的概率质量             -> K=64 够不够
"""
import argparse
import os
import sys

import numpy as np


def load(path):
    d = np.load(path, allow_pickle=True)
    return d


def entropy(p):
    return -(p * np.log(p + 1e-12)).sum(1)


def report(path, n_show=0):
    d = load(path)
    idx, val, tgt = d['idx'], d['val'], d['tgt']
    T = float(d['temperature'])
    N, K = idx.shape
    print(f"=== {os.path.basename(path)} ===")
    print(f"tokens {N}   topk {K}   T {T}")
    print(f"教师: {str(d['slim']).split('/')[-1]}")
    print()

    p = np.exp(val - val.max(1, keepdims=True))
    p /= p.sum(1, keepdims=True)

    agree = (idx[:, 0] == tgt).mean()
    ent = entropy(p).mean()
    print(f"[1] 教师 top-1 一致率      {agree*100:6.2f}%")
    print(f"[2] 软目标熵              {ent:6.3f} nats")
    print(f"    教师困惑度上界        {np.exp(ent):6.2f}")
    print(f"[3] top-1 平均概率        {p[:,0].mean():6.3f}")
    print(f"    top-1 概率中位数      {np.median(p[:,0]):6.3f}")

    # [4] 软目标 vs 硬标签: 若教师 = one-hot, KL(soft||hard) = -log p1
    hard_kl = -np.log(p[:, 0] + 1e-12).mean()
    print(f"[4] 软目标 vs one-hot 的 KL {hard_kl:6.3f} nats")
    print(f"    (0 = 教师完全确定; >0 = 有暗知识可供蒸馏)")

    # [6] Top-K 截断质量: q 教师真实分布中落在 Top-K 外的质量
    # 无法直接从 Top-K 恢复, 但可用"未归一化质量"估计:
    # 若 Top-K 已覆盖几乎全部 softmax 质量, 则 sum(exp(z_topk)) 应接近 1
    unnorm = np.exp(val).sum(1)            # 未除 T 时的截断质量
    print(f"[6] Top-K 覆盖估计         平均 exp(z_topk) 之和 = "
          f"{unnorm.mean():.3f}  (>1 因已除 T; 仅作趋势观察)")

    # [5] 温度扫描: 用原始 logits 无法重算, 但可说明当前 T 的效果
    print()
    print("[5] 温度对软目标的影响 (当前 T=%.1f, 熵 %.3f):" % (T, ent))
    for t2 in (1.0, 2.0, 3.0, 4.0, 6.0):
        # val 存的是 z/T, 要还原 z 再按新温度重算
        z = val * T
        p2 = np.exp(z / t2 - (z / t2).max(1, keepdims=True))
        p2 /= p2.sum(1, keepdims=True)
        e2 = entropy(p2).mean()
        print(f"    T={t2:4.1f} -> 熵 {e2:6.3f} nats  "
              f"(ppl {np.exp(e2):7.2f})")

    # 结论
    print()
    if agree < 0.3:
        print("!! 教师 top-1 一致率过低 (<30%), 教师可能不可信")
    if ent < 0.5:
        print("!! 软目标熵过低, 教师过度自信, 蒸馏信息量不足 -> 提高 T")
    if ent > 4.5:
        print("!! 软目标熵过高, 教师接近均匀, 信息量不足 -> 降低 T")
    if 1.5 <= ent <= 3.5:
        print("OK 软目标熵适中 (1.5~3.5 nats), 蒸馏可用")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    args = ap.parse_args()
    report(args.path)


if __name__ == "__main__":
    main()