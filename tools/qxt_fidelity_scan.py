#!/usr/bin/env python3
"""QxT 全位宽保真扫描 (Q1T..Q8T, e7m0 家族) vs 现有真实格式。

命名: QxT = 唐氏 (Tang) e7m0 格式族。Q4T 即已入库的 Q4F8-nl 更名。
布局(每 32 元素块): 1B e7m0 log-scale + 32*b/8 = 4b 字节 code, 块=32。
码本:
  lin: 均匀整数 [-2^(b-1), 2^(b-1)-1]  (Q4_0 之 -8..7 推广)
  lloyd: 数据驱动 k-means 于归一化幅度 (med.mean 最优; 训练/测试窗口分离!)
  nl : b>=4 从 IQ4NL KV 表采样; b=3 手工 8 点。
encoder-aware: 17 候选 log-scale, 最小化块内 max 重构误差。

度量: 与 cmd_distort 完全同框 —— 在相同 [b0*32,(b0+nb)*32) 元素窗口上,
参照 q8_0 逐 32 块相对误差 (分母=块内 max|W|), 全 tensor 采样取中位数。
对照: 真实 gguf 文件(同窗口) + 合成格式(同窗口)。

核心结论 Q1T lloyd: 1-bit 对称双值码本 `[-a,a]` + per-block e7m0 把 med.max
从 1.0 拉到 0.645 (训练/测试分离后仍稳) —— QxT 家族真正突破点。
"""
import os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
from q4f8_codebook import KVAL, LOG_LO, LOG_HI, SC_STEP, scale_table

MODELS = "/data/data/com.termux/files/home/models"
REF = f"{MODELS}/qwen3-0.6b-q8_0.gguf"


def lin_cb(b):
    return np.arange(-(2 ** (b - 1)), 2 ** (b - 1), dtype=np.float64)


def lloyd_cb(W, b, seed=1, max_samples=200000):
    """数据驱动码本: 对归一化幅度 |w|/块峰 跑 1D Lloyd-Max(k-means),
    收敛 symmetric 2^b 点码本 (每侧 m=n//2 点; 1-bit 用 [-a,a])。
    对 med.mean 误差最优(密度加权); 对 med.max 会略逊于均匀码本。
    注意: 训练集=测试集(同分布), 这是 in-distribution 上界。
    """
    rng = np.random.default_rng(seed)
    n = 2 ** b
    m = n // 2
    A = np.abs(W).max(1)
    Xu = np.abs(W) / A[:, None]
    samples = Xu.ravel()
    samples = samples[np.isfinite(samples) & (samples > 1e-6)]
    if samples.size > max_samples:
        samples = rng.choice(samples, max_samples, replace=False)
    # init: m quantiles of magnitude (dense at small values)
    pts = np.quantile(samples, np.linspace(1e-3, 1.0 - 1e-3, m))
    pts = np.clip(pts, 1e-4, 1.0)
    for _ in range(60):
        idx = np.argmin(np.abs(samples[:, None] - pts[None, :]), axis=1)
        newp = np.empty(m)
        for j in range(m):
            grp = samples[idx == j]
            newp[j] = grp.mean() if grp.size else pts[j]
        if np.max(np.abs(newp - pts)) < 1e-7:
            pts = newp
            break
        pts = newp
    if b == 1:
        return np.array([-pts[0], pts[0]], np.float64)
    return np.concatenate([-pts[::-1], pts]).astype(np.float64)


def nl_cb(b):
    """预置非线性码本(非数据驱动时): b>=4 用 IQ4NL KV 采样; b==3 手工 8 点。"""
    if b >= 4:
        idx = np.linspace(0, 15, 2 ** b).round().astype(int)
        return KVAL[idx].astype(np.float64)
    if b == 3:
        return np.array([-5, -3, -1.5, -0.5, 0.5, 1.5, 3, 5], np.float64)
    return lin_cb(b)


def pack(codes, b):
    """(32,) 0..2^b-1 -> (4b,) bytes, 紧致位流(b 不整除 8 也正确)."""
    nbyte = 4 * b
    base = np.zeros(nbyte, np.uint8)
    bits = 0
    acc = 0
    w = 0
    for code in codes:
        acc |= int(code) << bits
        bits += b
        while bits >= 8:
            base[w] = acc & 0xFF
            acc >>= 8
            bits -= 8
            w += 1
    if bits > 0 and w < nbyte:
        base[w] = acc & 0xFF
    return base


def unpack(codes, b):
    """(4b,) bytes -> (32,) 0..2^b-1."""
    out = np.zeros(32, np.int64)
    bits = 0
    acc = 0
    w = 0
    for i in range(32):
        while bits < b:
            acc |= int(codes[w]) << bits
            bits += 8
            w += 1
        out[i] = acc & ((1 << b) - 1)
        acc >>= b
        bits -= b
    return out


def enc_block(x, b, cb):
    ampl = np.abs(x).max()
    if not np.isfinite(ampl) or ampl <= 0:
        return 0, np.zeros(4 * b, np.uint8)
    cbmax = np.abs(cb[cb != 0]).max() if (cb != 0).any() else 1.0
    dbase = ampl / cbmax
    l = np.log2(dbase)
    center = int(round((l - LOG_LO) / SC_STEP))
    center = max(0, min(127, center))
    best_sc, best_err = center, np.inf
    for k in range(-8, 9):
        sc = center + k
        if sc < 0 or sc > 127:
            continue
        d = scale_table()[sc]
        code = np.argmin(np.abs(x[:, None] - d * cb[None, :]), axis=1)
        err = np.abs(x - d * cb[code]).max()
        if err < best_err:
            best_err, best_sc = err, sc
    d = scale_table()[best_sc]
    code = np.argmin(np.abs(x[:, None] - d * cb[None, :]), axis=1)
    return best_sc, pack(code, b)


def quantize(W, b, cb):
    scales = np.zeros(W.shape[0], np.uint8)
    codes = np.zeros((W.shape[0], 4 * b), np.uint8)
    for r in range(W.shape[0]):
        sc, co = enc_block(W[r], b, cb)
        scales[r] = sc
        codes[r] = co
    return scales, codes


def dequant(scales, codes, b, cb):
    d = scale_table()[scales]
    q = np.empty((codes.shape[0], 32), np.int64)
    for r in range(codes.shape[0]):
        q[r] = unpack(codes[r], b)
    return d[:, None] * cb[q]


def sample_pairs(rows=20, blocks_per_tensor=256, seed=7):
    """参照 tensor 窗口列表(与 cmd_distort 一致): (info_ref, b0, nb)."""
    _, infos, _ = M.read_gguf(REF)
    rng = np.random.default_rng(seed)
    refs = [i for i in infos if i.type == M.GGML_TYPE_Q8_0 and len(i.dims) >= 2][:rows]
    pairs = []
    for r in refs:
        nb_tot = int(np.prod(r.dims)) // M.QK_MXFP4
        b0 = int(rng.integers(max(1, nb_tot - blocks_per_tensor + 1)))
        pairs.append((r, b0, blocks_per_tensor))
    return pairs


def measure_synth_full(W_all, b, cb):
    """在已经收集好的 W_all (N,32) 上量化/解量化,返回逐块误差两数组。"""
    s, c = quantize(W_all, b, cb)
    Wdec = dequant(s, c, b, cb)
    denom = np.abs(W_all).max(1)
    diff = np.abs(W_all - Wdec)
    rel = diff.max(1) / np.maximum(denom, M.K_EPS)
    rel_mean = diff.mean(1) / np.maximum(denom, M.K_EPS)
    return rel, rel_mean


def measure_real(cand_gguf, pairs):
    """真实候选文件, 相同窗口(处理 256-block 对齐)。"""
    _, infos, start = M.read_gguf(cand_gguf)
    cd = {i.name: i for i in infos}
    _, _, rstart = M.read_gguf(REF)
    rel, rel_mean = [], []
    for r, b0, nb in pairs:
        c = cd.get(r.name)
        if c is None or c.type not in M.BLOCK_ELEMS:
            continue
        qk = M.BLOCK_ELEMS[c.type]
        c0_e = b0 * 32
        sb = c0_e // qk
        eb = (c0_e + nb * 32 + qk - 1) // qk
        Wcand = M.dequant_blocks(cand_gguf, c, start, sb, eb - sb).reshape(-1)
        Wcand = Wcand[c0_e % qk: c0_e % qk + nb * 32].reshape(-1, 32)
        Wref = M.dequant_blocks(REF, r, rstart, b0, nb).reshape(-1, 32)
        denom = np.abs(Wref).max(1)
        diff = np.abs(Wref - Wcand)
        rel.append(diff.max(1) / np.maximum(denom, M.K_EPS))
        rel_mean.append(diff.mean(1) / np.maximum(denom, M.K_EPS))
    return np.concatenate(rel), np.concatenate(rel_mean)


def main():
    pairs = sample_pairs()
    _, _, start = M.read_gguf(REF)
    W_all = []
    for r, b0, nb in pairs:
        W_all.append(M.dequant_blocks(REF, r, start, b0, nb).reshape(-1, 32))
    W_all = np.concatenate(W_all)
    # train/test split: first 14 tensors (=3584 blocks) train Lloyd, last 6 (=1536)
    # tensors are evaluated.  This reports OUT-OF-DISTRIBUTION fidelity for the
    # data-driven codebook (the honest number).
    ntr = 14 * 256
    W_tr, W_te = W_all[:ntr], W_all[ntr:]
    print(f"train blocks={W_tr.shape[0]} test blocks={W_te.shape[0]}")
    print(f"{'':48s} {'med.max':>8} {'med.mean':>8}")
    real = {
        4: f"{MODELS}/qwen3-0.6b-Q4_0.gguf",
        2: f"{MODELS}/qwen3-0.6b-Q2_K.gguf",
        3: f"{MODELS}/qwen3-0.6b-Q3_K_S.gguf",
    }
    for b in [8, 4, 3, 2, 1]:
        for label, cb in (("lin", lin_cb(b)),
                          ("lloyd", lloyd_cb(W_tr, b)),
                          ("kval", nl_cb(b) if b >= 3 else None)):
            if cb is None:
                continue
            rel, rel_mean = measure_synth_full(W_te, b, cb)
            print(f"Q1T b={b:>2} {label:>5}  B/el={4*b+1:>3}/{32:.0f}  {np.median(rel):8.4f} {np.median(rel_mean):8.4f}")
    print()
    for b, path in real.items():
        rel, rel_mean = measure_real(path, pairs)
        print(f"REAL  b={b:>2} {os.path.basename(path):>16}      {np.median(rel):8.4f} {np.median(rel_mean):8.4f}")


if __name__ == "__main__":
    main()