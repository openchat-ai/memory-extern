#!/usr/bin/env python3
"""mxfp8_lossless_entropy.py — 用熵反推"MXFP8 装 e6m7 是否可能无损".

原理(不猜分布):
  e6m7 熵=6.5bit(实测) 意味着"实际承载概率"的不同值基本 ≤ ~2^6.5≈90 个.
  MXFP8(E4M3) 8bit 每块能表示 256 个格点(1符号+4指数+3尾数), 块尺度全局缩放.
  → 若"每块(32元素)实际出现的不同 e6m7 值 ≤ 256 且能精确落格点" → 该块无损.
  → 判决: 统计真实权重按块分组后的不同值数分布, 看是否 ≤ MXFP8 可表示值数.

输入:
  --raw <bin>         真实权重(或e6m7已量化)的裸浮点
  --n                 若提供则合成高斯(无真实数据)
  --block 32
  --E 4 --M 3         MXFP8 配置(默认E4M3)

输出:
  每块不同值数分布(均值/95分位), 以及"块内不同值 ≤ 可无损表示值数"的块占比.
  >95% 块满足 → 无损可行; <90% → 有损.
"""
import argparse
import math
import numpy as np

def entropy_to_massive_values(ent):
    """熵→ 承载几乎全部概率所需的"质量值数"近似(2^H)."""
    return 2.0 ** ent

def block_distinct(W, block=32):
    """按块统计每块内不同浮点值数."""
    W1 = np.asarray(W, dtype=np.float32)
    tot = W1.size
    blk_vals = []
    for i in range(0, tot, block):
        blk = W1[i:i+block]
        if blk.size == 0:
            continue
        blk_vals.append(len(np.unique(blk)))
    return np.array(blk_vals, dtype=np.int64)

def mxfp8_capacity(E, M):
    """MXFP8 (E,M) 每块可表示的不同值数上限(格点数)."""
    return 2 ** (1 + E + M)   # 8bit 全格点

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw")
    ap.add_argument("--n", type=int, default=0, help="合成高斯样本数(无raw时)")
    ap.add_argument("--block", type=int, default=32)
    ap.add_argument("--E", type=int, default=4)
    ap.add_argument("--M", type=int, default=3)
    args = ap.parse_args()

    if args.raw:
        W = np.fromfile(args.raw, dtype=np.float32)
        src = args.raw
    elif args.n:
        rng = np.random.RandomState(0)
        W = rng.normal(0, 0.02, args.n).astype(np.float32)
        src = f"合成高斯({args.n})"
    else:
        print("需 --raw 或 --n"); return

    print(f"权重: {src}  元素={W.size:,}")
    # 熵
    vals, cnt = np.unique(W, return_counts=True)
    fr = cnt / cnt.sum()
    ent = -np.sum(fr * np.log2(fr + 1e-30))
    mass_vals = entropy_to_massive_values(ent)
    print(f"权重熵(直接) = {ent:.3f} bit → 承载主要概率所需值数≈{mass_vals:.0f}")

    blk_dist = block_distinct(W, args.block)
    cap = mxfp8_capacity(args.E, args.M)
    print(f"\nMXFP8 E{args.E}M{args.M} 每块容量 = {cap} 格点")
    print(f"每块(block={args.block})不同值数: 均值={blk_dist.mean():.1f}  "
          f"中位={np.median(blk_dist):.0f}  95分位={np.percentile(blk_dist,95):.0f}  最大={blk_dist.max()}")
    ok = int((blk_dist <= cap).sum())
    ratio = ok / len(blk_dist)
    print(f"\n→ 每块不同值 ≤ {cap} 的块占比: {ratio*100:.1f}%")
    print("  ⚠ 注意: 这是'格点数量足够'的宽松判据, 不是无损保证!")
    print("  ⚠ 真正无损还要求每块的值精确落到共享scale的MXFP8格点(见 mxfp8_lossless_dist.py)")
    if args.raw:
        print("  (有真实数据→可用 mxfp8_lossless_dist.py 做精确逐块无损验证)")
    else:
        print("  (合成数据→仅是方向性参考, 不能当真实无损结论)")

if __name__ == "__main__":
    main()