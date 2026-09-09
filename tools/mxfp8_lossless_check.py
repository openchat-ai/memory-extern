#!/usr/bin/env python3
"""mxfp8_lossless_check.py — MXFP8(8bit) 能否无损表示 e6m7(14bit) 探测.

背景: e6m7(14bit) → MXFP8(8bit) 要求**无损**, 且推理无解压(压缩格式直接计算).
本工具只测硬前提: MXFP8 能否对 e6m7 的每个离散值精确重建(表示范围内无损).
若数学上不可行(E4M3尾数3 vs e6m7尾数7), 则"无损MXFP8"无解, 及早发现.

e6m7 值 = sign × (1 + m/128) × 2^(e-bias31),  e∈[0,63], m∈[0,127]   ← 可枚举
MXFP8 值 = block_scale × sign × (1 + m'/2^M) × 2^(e'-bias), per-block scale.

检查:
  对每个 e6m7 离散值 v, 扫所有 (scale, e', m') 是否能精确等于 v
  scale 由块内最大值决定; 因此逐块检查"块内所有 e6m7 值是否都被该块的
  MXFP8 格点精确覆盖".

用法:
  python3 mxfp8_lossless_check.py                # 枚举 e6m7 vs E4M3 全集 (理论上限)
  python3 mxfp8_lossless_check.py --raw <bin>    # 对真实权重检查(若有)
"""
import argparse
import itertools
import numpy as np

# E4M3 (MXFP8默认): 1 sign + 4 exp + 3 mantissa
def e6m7_values():
    """枚举 e6m7 全部可表示值(不含0). 返回 dict: value -> (e,m) 或 None."""
    bias = 31
    out = {}
    for s in [1, -1]:
        for e in range(64):
            for m in range(128):
                v = s * (1.0 + m / 128.0) * (2.0 ** (e - bias))
                out[v] = (e, m)
    return out

def mxfp8_encode(val, E, M, scale, bias):
    """把 val/scale 量化到 eXmY 的 (e', m', ok)."""
    v = val / scale
    sign = 1 if v >= 0 else -1
    mag = abs(v)
    if mag == 0:
        return (0, 0, True)
    e = int(np.floor(np.log2(mag)))
    max_e = 2 ** E - 1
    # 归一化尾数
    norm = mag / (2.0 ** e)
    m_frac = (norm - 1.0) * (2.0 ** M)
    m_int = int(round(m_frac))
    if m_int < 0 or m_int > (2 ** M - 1):
        return (e, -1, False)
    # 指数范围检查
    if e < -bias or e > (max_e - bias):
        return (e, -1, False)
    rec = sign * (1.0 + m_int / (2.0 ** M)) * (2.0 ** e) * scale
    return (e, m_int, True, rec)

def lossless_theoretical(E, M, block_scale_base=1.0, scales_per_block=1):
    """全局(块尺度唯一化后)无损检查: 枚举每 scale, 看 e6m7 每个值能否在
    某个 scale 下被 MXFP8 精确覆盖. 返回覆盖率与未覆盖示例.
    注: 这是"理论可无损上限", 真实块内还会有块尺度冲突."""
    e6 = e6m7_values()
    bias = 2 ** (E - 1) - 1
    # 尝试多 scale(2 的幂), 看能否用块尺度把这些值"对齐"到 MXFP8 格点
    total = len(e6)
    covered = set()
    uncon = []
    # scale 取 2 的 s, s 从 -40..40 扫
    for s in range(-40, 41):
        scale = 2.0 ** s
        for v in e6:
            if v in covered:
                continue
            r = mxfp8_encode(v, E, M, scale, bias)
            if r[2]:
                # 精确重建检查
                (e, m, ok, rec) = r
                if abs(rec - v) < 1e-12:
                    covered.add(v)
    coverage = len(covered) / total
    # 未覆盖(可能被块尺度覆盖不了的值)
    return coverage, total, covered

def lossless_blockcheck(W, E, M, block=32):
    """对真实权重逐块检查: 每块取块内 amax 得 scale, 验证该块内所有 e6m7
    值能否被这个 scale 下的 MXFP8 精确表示(无损判据)."""
    W = np.asarray(W, dtype=np.float32).reshape(1, -1)[0]
    bias = 2 ** (E - 1) - 1
    n = W.shape[0]
    n_lossless = 0
    n_total = 0
    bad_blocks = []
    for i in range(0, n, block):
        blk = W[i:i+block]
        if blk.size == 0:
            continue
        amax = np.max(np.abs(blk)) if blk.size else 0.0
        if amax == 0:
            n_lossless += blk.size
            n_total += blk.size
            continue
        # scale = 2^floor(log2(amax)) (简单方案)
        s = int(np.floor(np.log2(amax)))
        scale = 2.0 ** s
        ok_cnt = 0
        for v in blk:
            n_total += 1
            if v == 0:
                ok_cnt += 1
                continue
            r = mxfp8_encode(v, E, M, scale, bias)
            if r[2] and abs(r[3] - v) < 1e-12:
                ok_cnt += 1
        if ok_cnt == blk.size:
            n_lossless += blk.size
            bad_blocks.append(-1)
        else:
            bad_blocks.append(blk.size - ok_cnt)
    return n_lossless, n_total, bad_blocks

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw")
    args = ap.parse_args()

    print("=== 理论无损上限: e6m7 全集 vs MXFP8 (E,M) 配置 ===")
    for E, M in [(4, 3), (5, 2), (6, 1)]:
        coverage, total, covered = lossless_theoretical(E, M)
        print(f"  E{E}M{M}: 覆盖率 {coverage*100:.2f}%  ({len(covered)}/{total} 值可被某scale精确表示)")
        if coverage < 1.0:
            # 展示几个不可无损覆盖的值
            e6 = e6m7_values()
            uncon_ex = []
            for v in e6:
                if v not in covered:
                    uncon_ex.append(v)
                if len(uncon_ex) >= 5:
                    break
            print(f"    未覆盖示例: {[round(x,7) for x in uncon_ex]}")

    if args.raw:
        W = np.fromfile(args.raw, dtype=np.float32)
        print(f"\n=== 真实权重无损块检查: {args.raw} ===")
        for E, M in [(4, 3), (5, 2), (6, 1)]:
            nl, nt, bad = lossless_blockcheck(W, E, M)
            print(f"  E{E}M{M}: 无损块覆盖 {nl}/{nt} = {nl/max(1,nt)*100:.2f}%")


if __name__ == "__main__":
    main()