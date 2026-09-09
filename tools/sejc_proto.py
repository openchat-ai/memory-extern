#!/usr/bin/env python3
"""SEJC 原型: 谱-指数联合压缩 (Spectral-Exponent Joint Compression)
应用 zipNN思路到奇异值上, 验证压缩率和解压率
"""
import numpy as np
import time

# ---------- 生成一个小的专家权重模拟 ----------
def gen_expert(n=512, seed=42):
    np.random.seed(seed)
    # 幂律奇异值结构的权重(类似真实LLM)
    U = np.linalg.qr(np.random.randn(n, n))[0]
    V = np.linalg.qr(np.random.randn(n, n))[0]
    s = np.exp(-np.arange(n) / (n * 0.15))  # 快速衰减的奇异值
    W = (U * s) @ V.T
    return W.astype(np.float32)

# ---------- zipNN 的指数 Huffman 思路, 用于存储 ----------
from collections import Counter
import heapq

def huffman_codes(counts):
    heap = [[w, [sym, ""]] for sym, w in counts.items()]
    heapq.heapify(heap)
    while len(heap) > 1:
        lo = heapq.heappop(heap)
        hi = heapq.heappop(heap)
        for pair in lo[1:]:
            pair[1] = '0' + pair[1]
        for pair in hi[1:]:
            pair[1] = '1' + pair[1]
        heapq.heappush(heap, [lo[0] + hi[0]] + lo[1:] + hi[1:])
    return dict(sorted(heapq.heappop(heap)[1:], key=lambda p: (len(p[-1]), p)))

def entropy_of_stream(values):
    c = Counter(values)
    n = len(values)
    e = 0
    for cnt in c.values():
        p = cnt / n
        e -= p * np.log2(p)
    return e, len(c)

# ---------- 方法1: 直接存储单精度 ----------
def method_baseline(W):
    nbits = W.nbytes * 8
    return nbits

# ---------- 方法2: zipNN 思路(逐weight 指数+尾数熵编码) ----------
def method_zipnn(W):
    flat = W.flatten().view(np.int32)
    # 分离指数和尾数 (IEEE754 fp32)
    exp = (flat >> 23) & 0xFF
    mant = flat & 0x3FFFFF
    sign = (flat >> 31) & 0x1
    e, esym = entropy_of_stream(exp.tolist())
    em, msym = entropy_of_stream(mant.tolist())
    es, ssym = entropy_of_stream(sign.tolist())
    nbits = len(flat) * (e + em + es)
    return nbits, esym, msym, ssym

# ---------- 方法3: SEJC (奇异值用zipNN, U/V量化) ----------
def method_sejc(W, rank_keep=None, mant_bits=8):
    n = W.shape[0]
    U, S, Vt = np.linalg.svd(W, full_matrices=False)
    if rank_keep is None:
        rank_keep = n
    S = S[:rank_keep]
    U = U[:, :rank_keep]
    Vt = Vt[:rank_keep, :]
    # 奇异值熵编码(通常分布很尖锐->可压缩)
    eS, sS = entropy_of_stream(S.tolist())
    # U, V 量化后存储
    # 这里用 mant_bits 量化 U/V (正交矩阵元素分布较平)
    nbits = rank_keep * np.log2(rank_keep)   # S符号/索引
    nbits += rank_keep * eS                  # 奇异值熵编码
    nbits += 2 * n * rank_keep * mant_bits   # U,V量化位
    return nbits, rank_keep, eS

# ---------- 跑对比 ----------
for n in [64, 256]:
    print(f"\n=== expert size {n}x{n} (参数量 {n*n:,}) ===")
    W = gen_expert(n)

    # baseline
    nb = method_baseline(W)
    print(f"baseline fp32:      {nb/8:>12,} bytes  {nb/(n*n):.2f} bits/weight")

    # zipnn 无损
    nzp, es, ms, ss = method_zipnn(W)
    print(f"zipNN-style:        {nzp/8:>12.0f} bytes  {nzp/(n*n):.2f} bits/weight  (无损)")

    # SEJC: 保留不同秩 + 8bit量化U,V
    for r in [n//4, n//8]:
        ns, rk, eS = method_sejc(W, rank_keep=r, mant_bits=8)
        print(f"SEJC rank={rk:>3} 8b: {ns/8:>12.0f} bytes  {ns/(n*n):.2f} bits/weight  "
              f"(U,V量化8bit, 奇异值熵编码{eS:.1f}bits)")

    # SEJC 极限: 保持90%能量所需秩
    U, S, Vt = np.linalg.svd(W)
    tot = (S**2).sum()
    cum = np.cumsum(S**2)
    r90 = int(np.searchsorted(cum, 0.9*tot)+1)
    ns, rk, eS = method_sejc(W, rank_keep=r90, mant_bits=6)
    print(f"SEJC 90%能量 rank={r90}: {ns/8:>12.0f} bytes  {ns/(n*n):.2f} bits/weight  (6bit U/V)")