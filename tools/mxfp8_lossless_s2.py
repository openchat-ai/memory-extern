#!/usr/bin/env python3
"""mxfp8_lossless_s2.py — 修正版: 逐块扫所有候选 scale=2^s, 判无损.

之前错误: 块只试 scale=2^floor(log2(amax)) 一个值 → 6% 假象.
正确: 块的候选 s 来自块内每个非零值的指数(取 log2(|v|) 的整数部分 +-范围),
      只要存在一个 s 使块内全部权重精确落到 MXFP8 格点 → 该块无损.
      指数上限与唯一值数都和判据无关(二幂结构 e, scale 的 s 均可无限).

判据(与唯一值数无关): 每个权重 v=(k,v)二幂结构, 能否被
  v = scale(2^s) × sign × (1+m/2^M) × 2^e'  (e' 在指数位宽) 精确重建.

用法: python3 mxfp8_lossless_s2.py --raw <bin> [--block 32] [--E 4 --M 3]
"""
import argparse
import math
import numpy as np

def can_represent(v, s, E, M):
    """v 是否可被 scale=2^s 的 EeMy 格点精确表示."""
    if v == 0:
        return True
    val = abs(v) / (2.0 ** s)
    sign = 1.0
    e = int(math.floor(math.log2(val)))
    max_e = 2 ** E - 1
    bias = 2 ** (E - 1) - 1
    # 规范化尾数
    norm = val / (2.0 ** e)
    m_int = round((norm - 1.0) * (2.0 ** M))
    if m_int < 0 or m_int > (2 ** M - 1):
        return False
    if e > (max_e - bias):
        return False
    # subnormal 允许 e = -bias
    if e < -bias:
        return False
    rec = sign * (1.0 + m_int / (2.0 ** M)) * (2.0 ** e) * (2.0 ** s)
    return abs(rec - abs(v)) < 1e-12

def block_lossless_any_scale(blk, E, M):
    """块内全部权重, 是否存在一个 s 使全部可精确表示."""
    blk = np.asarray(blk, dtype=np.float64).reshape(-1)
    nz = blk[np.abs(blk) > 0]
    if nz.size == 0:
        return True
    # 候选 s: 每个非零值需要的 s 范围(对应的指数基线)
    logs = np.floor(np.log2(np.abs(nz))).astype(int)
    floor_e = logs.min()
    ceil_e = logs.max()
    bias = 2 ** (E - 1) - 1
    max_e = 2 ** E - 1
    # s 取值范围: 让块内指数都落进 [-bias, max_e-bias]
    s_min = ceil_e - (max_e - bias)
    s_max = floor_e + bias
    for s in range(s_min, s_max + 1):
        if all(can_represent(v, s, E, M) for v in blk):
            return True
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--block", type=int, default=32)
    ap.add_argument("--E", type=int, default=4)
    ap.add_argument("--M", type=int, default=3)
    args = ap.parse_args()

    W = np.fromfile(args.raw, dtype=np.float32)
    W64 = W.astype(np.float64)
    n = W.size
    ok = 0
    total = 0
    for i in range(0, n, args.block):
        blk = W64[i:i+args.block]
        if blk.size == 0:
            continue
        total += 1
        if block_lossless_any_scale(blk, args.E, args.M):
            ok += 1
    print(f"权重: {args.raw}  块={args.block}  E{args.E}M{args.M}")
    print(f"存在s使整块无损的块: {ok}/{total} = {ok/max(1,total)*100:.2f}%")
    print("判据: 若==100%, 则'8bit MXFP8 + 逐块选s'可完全无损装 e6m7。")

if __name__ == "__main__":
    main()