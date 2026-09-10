#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""svd_probe.py - K3 权重张量的低秩性研究 (Matryoshka 降维适用性)

问题: 高维权重矩阵能不能用 rank-r 分解(改低维)还不掉质量?
方法: 对层切片里的代表性张量解码回 f32, 算奇异值谱, 报告:
      - 有效秩(捕捉 50/90/95/99/99.9% 能量的最小 r)
      - rank-r 分解 vs 原矩阵的 energy error / argmax 保真(@ 高斯输入)
      - 与 8bit 量化(现状)对照 —— 判断"降维"比"降位"谁更适合
用法: svd_probe.py <layers_dir> <layers.json> <layer_id> <tensor_name>
"""
import json, math, sys
import numpy as np

def decode_mxfp8_128(packed, rows, cols, ngrp):
    dec = np.zeros((rows, cols), np.float32)
    for r in range(rows):
        row = packed[r].ravel()
        scales, codes = row[:ngrp], row[ngrp:]
        for g in range(ngrp):
            e = int(scales[g]); e = e - 256 if e >= 128 else e
            gs = math.ldexp(1.0, e - 6)
            lo, hi = g * 128, min((g + 1) * 128, cols)
            seg = codes[lo:hi]
            mag = (seg & 0x7F).astype(np.float32)
            neg = (seg >> 7).astype(np.float32)
            dec[r, lo:hi] = np.where(neg == 1, -mag, mag) * gs
    return dec

def report_rank(tag, ref, x, a_ref, nbytes_orig, rank_list=(16, 32, 64, 128, 256, 512)):
    R, C = ref.shape
    ne = R * C
    try:
        U, s, Vt = np.linalg.svd(ref, full_matrices=False)
    except np.linalg.LinAlgError:
        print("  %-24s SVD 失败" % tag)
        return
    e2 = s ** 2
    etot = e2.sum()
    print("  %-26s 奇异值谱: 数 %d, Σ能量前三占比 %.2f/%.2f/%.2f%%"
          % (tag, s.size, 100*e2[0]/etot, 100*e2[1]/etot, 100*e2[2]/etot))
    for r in rank_list:
        kept = 100 * e2[:r].sum() / etot
        A = U[:, :r] @ np.diag(s[:r]) @ Vt[:r, :]
        err = A - ref
        nz = np.abs(ref) > 1e-30
        energy = np.sqrt((err[nz] ** 2).sum() / (ref[nz] ** 2).sum())
        same = (a_ref == np.argmax(x @ A.T, axis=1)).mean()
        # 存储: 两个小矩阵, 用 8bit scale 量化 → 近似
        nbytes_r = r * (R + C)  # fp32 假设; 量化后更低
        bpe = 8 * nbytes_r / ne
        print("    rank%-4d 能量%-6.2f%%  Eerr %6.2f%%  argmax %5.1f%%  (%d B/张量=%.2f bit/elem fp32)"
              % (r, kept, energy * 100, same * 100, nbytes_r, bpe))
    # 参考: 8bit e8m7 现状误差
    print("    8bit MXFP8 现状误差 ≈ 3-7%(doc 口径), trunk 8.06 bit/elem")

def main():
    trunk, layers_json, li, tname = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    man = json.load(open(layers_json))
    lay = man["layers"][li]
    t = lay["tensors"][tname]
    raw = open("%s/layer_%03d.bin" % (trunk, li), "rb").read()
    rows, cols = int(t["shape"][0]), int(t["shape"][1])
    ngrp = int(t["ngrp"])
    packed = np.frombuffer(raw[int(t["off"]): int(t["off"]) + int(t["nbytes"])], np.uint8).reshape(rows, ngrp + cols)
    ref = decode_mxfp8_128(packed, rows, cols, ngrp)
    x = np.random.default_rng(7).standard_normal((16, cols)).astype(np.float32)
    a_ref = np.argmax(x @ ref.T, axis=1)
    print("tensor %s [%d, %d]  elems %.1fM" % (tname, rows, cols, rows*cols/1e6))
    # 子块谱分析: 随机 4 个 256×256 块, 奇异值谱平均 (推断全局谱)
    print("=== 随机 256×256 子块奇异值谱 (每块独立 SVD, 4 块平均) ===")
    acc = None
    rngr = np.random.default_rng(0)
    for _ in range(4):
        ri = rngr.choice(rows, 256, replace=False)
        ei = rngr.choice(cols, 256, replace=False)
        U, s, Vt = np.linalg.svd(ref[np.ix_(ri, ei)], full_matrices=False)
        e2 = s ** 2
        e2 = e2 / e2.sum()
        if acc is None:
            acc = e2
        else:
            acc = acc[:len(e2)] + e2
    acc /= 4
    c = np.cumsum(acc)
    print("行谐: 能量捕获前 r 维占比")
    for r in (4, 8, 16, 32, 64, 128, 256):
        print("  r=%-4d 能量 %.1f%%" % (r, 100 * c[r-1]))
    print("\n=== 全阵 rank-r 近似 (SVD on 256×256 子块, 在子块上 eval) ===")
    ri = np.random.default_rng(0).choice(rows, 256, replace=False)
    ei = np.random.default_rng(1).choice(cols, 256, replace=False)
    sub = ref[np.ix_(ri, ei)]
    xs = x[:, ei]
    ar = np.argmax(xs @ sub.T, axis=1)
    U, s, Vt = np.linalg.svd(sub, full_matrices=False)
    e2 = s ** 2; etot = e2.sum()
    for r in (8, 16, 32, 64, 128, 256):
        kept = 100 * e2[:r].sum() / etot
        Ap = U[:, :r] @ np.diag(s[:r]) @ Vt[:r, :]
        err = Ap - sub
        nz = np.abs(sub) > 1e-30
        energy = np.sqrt((err[nz] ** 2).sum() / (sub[nz] ** 2).sum())
        same = (ar == np.argmax(xs @ Ap.T, axis=1)).mean()
        # storage: 两小阵, fp16 也够(中间), 用 fp16 算
        nbytes_r = r * (rows + cols) * 2  # fp16
        print("  rank%-4d 能量keep%-5.1f%%  Eerr %6.2f%%  argmax %5.1f%%  ~%.2f bit/elem(fp16)"
              % (r, kept, energy * 100, same * 100, 8 * nbytes_r / (rows*cols)))

main()