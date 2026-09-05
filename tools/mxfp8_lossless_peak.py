#!/usr/bin/env python3
"""mxfp8_lossless_peak.py — 用"熵=6.5bit 的峰值分布"验证 MXFP8 无损可行性.

背景: 真实dense经e6m7量化后熵=6.5bit(用户实测). 高斯分布熵是10.45,不匹配,
说明真实分布高度偏斜: 少量e6m7值承载几乎全部概率质量(峰值/尖峰分布).
本脚本构造"能产生6.5bit熵"的尖峰稀疏分布, 验证其高频值能否被MXFP8格点覆盖.

若高频核心值落在MXFP8 8bit格点上且覆盖>99.9%, 则"无损MXFP8"成立(在真实分布下).
"""
import argparse
import math
import numpy as np

def spike_dist(n=300_000, std=0.02, n_support=40):
    """构造熵≈6.5bit 的尖峰分布: 少量核心e6m7值,幂律频率."""
    rng = np.random.RandomState(1)
    # 核心值: 取高斯采样的一小撮点作为"高频格点"
    support = np.unique(np.round(rng.normal(0, std, n_support) / 0.001) * 0.001).astype(np.float32)
    if len(support) < 4:
        support = np.array([0.0, 0.001, -0.001, 0.002, -0.002, 0.005, -0.005, 0.01], dtype=np.float32)
    # 幂律权重
    probs = 1.0 / (np.arange(1, len(support) + 1) ** 1.1)
    probs /= probs.sum()
    idx = rng.choice(len(support), size=n, p=probs)
    return support[idx].astype(np.float32)

def quant_e6m7(W):
    W = np.asarray(W, dtype=np.float32)
    mag = np.abs(W)
    sign = np.sign(W)
    nz = mag > 0
    e = np.zeros(mag.shape, dtype=np.float32)
    e[nz] = np.floor(np.log2(mag[nz]))
    bias = 31
    ei = np.clip(e + bias, 0, 63)
    norm = np.ones(mag.shape, dtype=np.float32)
    norm[nz] = mag[nz] / (2.0 ** e[nz])
    m = np.clip(np.round((norm - 1.0) * 128.0), 0, 127).astype(np.int64)
    rec = (1.0 + m.astype(np.float32) / 128.0) * (2.0 ** (ei - bias))
    Wq = np.where(sign >= 0, rec, -rec)
    Wq[~nz] = 0.0
    return Wq.astype(np.float32)

def mxfp8_canrepresent(v, E, M, scale, bias):
    if v == 0:
        return True
    val = v / scale
    sign = 1 if val >= 0 else -1
    mag = abs(val)
    e = int(math.floor(math.log2(mag)))
    max_e = 2 ** E - 1
    if e < -bias or e > (max_e - bias):
        return False
    norm = mag / (2.0 ** e)
    m_int = round((norm - 1.0) * (2.0 ** M))
    if m_int < 0 or m_int > (2 ** M - 1):
        return False
    rec = sign * (1.0 + m_int / (2.0 ** M)) * (2.0 ** e) * scale
    return abs(rec - v) < 1e-12

def block_lossless(Wq, E, M, block=32):
    n = Wq.size
    w1 = Wq.reshape(1, -1)[0]
    bias = 2 ** (E - 1) - 1
    nloss = 0
    for i in range(0, n, block):
        blk = w1[i:i+block]
        if blk.size == 0:
            continue
        amax = np.max(np.abs(blk))
        if amax == 0:
            nloss += blk.size
            continue
        s = int(math.floor(math.log2(amax)))
        scale = 2.0 ** s
        ok = np.array([mxfp8_canrepresent(v, E, M, scale, bias) for v in blk])
        nloss += int(ok.sum())
    return nloss / max(1, n)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=300_000)
    ap.add_argument("--block", type=int, default=32)
    args = ap.parse_args()

    entropy_target = 6.5

    # 找能产生6.5bit熵的峰度参数
    print("=== 构造熵≈6.5bit 的尖峰分布并测 MXFP8 无损 ===")
    best = None
    for sup in [20, 40, 80, 160]:
        for exp in [1.0, 1.3, 1.7, 2.0, 2.5]:
            Ws = spike_dist(args.n, n_support=sup)
            Wq = quant_e6m7(Ws)
            vals, cnt = np.unique(Wq, return_counts=True)
            fr = cnt / cnt.sum()
            ent = -np.sum(fr * np.log2(fr + 1e-30))
            if abs(ent - entropy_target) < 0.4:
                # 测E4M3 32块无损率
                for E, M, name in [(4,3,"E4M3"),(5,2,"E5M2")]:
                    wl = block_lossless(Wq, E, M, args.block)
                    status = "可无损" if wl > 0.999 else ("边缘" if wl > 0.95 else "有损")
                    print(f"  sup={sup:>3} exp={exp:<4} 熵={ent:.3f}bit  E{M} block={args.block} 无损率={wl*100:6.2f}% [{status}]")
                    if wl > 0.999 and (best is None or ent < best[0]):
                        best = (ent, sup, exp, E, M, wl)
    print()
    if best:
        print(f"✓ 找到可无损组合: 熵{best[0]:.2f}bit, sup={best[1]}, E{best[3]}M{best[4]}, 无损率{best[5]*100:.2f}%")
    else:
        print("✗ 未见可无损组合 — 需真实分布判定")

if __name__ == "__main__":
    main()