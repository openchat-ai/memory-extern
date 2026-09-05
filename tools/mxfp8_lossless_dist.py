#!/usr/bin/env python3
"""mxfp8_lossless_dist.py — 基于"实际分布"判断 MXFP8(8bit)能否无损装 e6m7.

修正: 之前用全集16384枚举(6.25%)是错的. e6m7熵=6.5bit(用户实测无损),
信息量只有6.5 => 8bit容器理论上够. 无损取决于**实际出现的值**能否被
MXFP8格点+块尺度精确覆盖(无需覆盖全集).

方法:
  1. 生成近似真实dense的高斯权重(mean0,std~0.02,匹配K3 dense分布)
  2. 量化到 e6m7(14bit) [用户已完成的那步]
  3. 统计 e6m7 各离散值出现频率(按实际分布)
  4. 对 MXFP8 多配置(E,M,block), 逐块检查: 该块内所有e6m7实际值
     能否被 block scale 对齐的 MXFP8 格点精确表示
  5. 输出"无损覆盖率(按频率加权)" — 越接近100%说明无损真可行
"""
import argparse
import math
import numpy as np

def synth_dense(n=1_000_000, std=0.02):
    """合成近似真实dense权重的分布."""
    rng = np.random.RandomState(0)
    W = rng.normal(0, std, n)
    return W.astype(np.float32)

def quant_e6m7(W):
    """BF16 → e6m7 (bias31), 返回量化后的值与占用的(e,m)索引(高频)."""
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
    """v 能否被 MXFP8 (E,M,scale) 格点精确表示."""
    if v == 0:
        return True
    val = v / scale
    sign = 1 if val >= 0 else -1
    mag = abs(val)
    e = int(np.floor(math.log2(mag)))
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
    """逐块检查: 块内所有e6m7值能否被该块scale对齐的格点精确表示.
    返回 (按频率加权的无损率, 严格每块全无损的块占比)."""
    n = Wq.size
    W1 = Wq.reshape(1, -1)[0]
    bias = 2 ** (E - 1) - 1
    nloss = 0
    n_ok_blocks = 0
    n_blocks_total = 0
    for i in range(0, n, block):
        blk = W1[i:i+block]
        if blk.size == 0:
            continue
        amax = np.max(np.abs(blk))
        if amax == 0:
            nloss += blk.size
            n_ok_blocks += 1
            n_blocks_total += 1
            continue
        s = int(np.floor(math.log2(amax)))
        scale = 2.0 ** s
        ok = np.array([mxfp8_canrepresent(v, E, M, scale, bias) for v in blk])
        nloss += int(ok.sum())
        if ok.all():
            n_ok_blocks += 1
        n_blocks_total += 1
    return nloss / max(1, n), n_ok_blocks / max(1, n_blocks_total)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=1_000_000)
    ap.add_argument("--std", type=float, default=0.02)
    ap.add_argument("--block", type=int)
    args = ap.parse_args()

    W = synth_dense(args.n, args.std)
    Wq = quant_e6m7(W)
    # 熵(无损下界)复核
    vals, cnt = np.unique(Wq, return_counts=True)
    fr = cnt / cnt.sum()
    ent = -np.sum(fr * np.log2(fr + 1e-30))
    print(f"合成dense: n={args.n:,} std={args.std}")
    print(f"e6m7量化后: 唯一值数={len(vals):,}  熵={ent:.3f} bit/权重 (应≈6.5附近)")
    print()

    configs = [(4,3,"E4M3"), (5,2,"E5M2"), (6,1,"E6M1")]
    blocks = [8, 32, 64] if args.block is None else [args.block]
    print("=== MXFP8 无损可行性 (按实际分布, 频率加权) ===")
    print(f"{'配置':<8} {'块':<5} {'频率加权无损%':<16} {'逐块全无损块%'}")
    for E, M, name in configs:
        for b in blocks:
            wloss, blk_ok = block_lossless(Wq, E, M, b)
            verdict = "✓可行" if wloss > 0.999 else ("✗有损" if wloss < 0.99 else "~边缘")
            print(f"{name:<8} {b:<5} {wloss*100:<16.4f} {blk_ok*100:<10.2f} {verdict}")
    print("\n判断: 无损率>99.9%(接近位完美)才可称'无损装e6m7'.")

if __name__ == "__main__":
    main()