#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""mrl_sweep.py - Matryoshka 压缩残差占比扫描

对单张量扫 resid 稀疏度 k%, 报告 bit/elem / energy% / argmax%(64 随机高斯输入),
输出决定"最大压缩且保真"的拐点。格式: base(4bit E2M1/p128) + 残差 top-k%(8bit E8M7/p128)。

用法: mrl_sweep.py <trunk_dir> <layers.json> <layer_id> <tensor_name>
"""
import json, math, sys
import numpy as np

E2M1_POS = np.array([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0], dtype=np.float32)

def entropy_hist(b, maxv):
    c = np.bincount(b.astype(np.uint64), minlength=maxv)
    c = c[c > 0].astype(np.float64)
    p = c / c.sum()
    return float(-(p * np.log2(p)).sum())

def quant_e8m7_128(f32, group=128):
    R, C = f32.shape
    ngrp = (C + group - 1) // group
    W = ngrp * group
    a = np.abs(f32)
    if W > C:
        a = np.pad(a, ((0, 0), (0, W - C)), mode="constant")
    blocks = a.reshape(R, ngrp, group)
    amax = blocks.max(axis=-1).astype(np.float64)
    e_d = np.zeros_like(amax)
    nz = amax > 0
    with np.errstate(divide="ignore"):
        e_d[nz] = np.floor(np.log2(amax[nz]))
    e_d = np.clip(e_d, -128, 127)
    e_i = e_d.astype(np.int8)
    scale2 = np.exp2(e_d)
    m = (blocks.astype(np.float64) / scale2[:, :, None]).reshape(R, W)
    step = 2.0 / (1 << 7)
    m_q = np.clip(np.round(m / step), 0, 127).astype(np.uint8)
    neg = (f32 < 0).astype(np.uint8)
    codes = (m_q[:, :C] | (neg << 7)).astype(np.uint8)
    return codes, e_i

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

def quant_fp4_per128(f32, group=128):
    R, C = f32.shape
    ngrp = (C + group - 1) // group
    W = ngrp * group
    a = np.abs(f32)
    if W > C:
        a = np.pad(a, ((0, 0), (0, W - C)), mode="constant")
    blocks = a.reshape(R, ngrp, group)
    amax = blocks.max(axis=-1).astype(np.float64)
    e_d = np.zeros_like(amax)
    nz = amax > 0
    with np.errstate(divide="ignore"):
        e_d[nz] = np.floor(np.log2(amax[nz] / 6.0))
    e_d = np.clip(e_d, -127, 127)
    e_i = e_d.astype(np.int8)
    sc2 = np.exp2(e_d)
    nm = (blocks.astype(np.float64) / sc2[:, :, None]).reshape(R, W)
    E2 = E2M1_POS
    idx = np.abs(E2[None, None, :] - nm[..., None]).argmin(axis=-1)
    idx = idx[:, :C]
    neg = (f32 < 0).astype(np.uint8)
    ni = (idx & 0x07) | (neg << 3)
    pcode = np.zeros((R, (C + 1) // 2), np.uint8)
    ev, od = ni[:, 0::2], ni[:, 1::2]
    m = min(ev.shape[1], od.shape[1])
    pcode[:, :m] = ev[:, :m] | (od[:, :m] << 4)
    if C % 2 == 1:
        pcode[:, -1] = ev[:, -1]
    return pcode, e_i

def decode_fp4_per128(pcode, scale, rows, cols, ngrp):
    dec = np.zeros((rows, cols), np.float32)
    for r in range(rows):
        for g in range(ngrp):
            e = int(scale[r, g]); e = e - 256 if e >= 128 else e
            gs = math.ldexp(1.0, e)
            lo, hi = g * 128, min((g + 1) * 128, cols)
            nib = pcode[r, lo // 2:(hi + 1) // 2]
            E = np.zeros(hi - lo, np.uint8)
            E[0::2] = nib & 0x0F
            E[1::2] = (nib >> 4) & 0x0F
            val = np.where((E >> 3) & 1, -1.0, 1.0) * E2M1_POS[E & 0x07]
            val[E == 0] = 0
            dec[r, lo:hi] = val * gs
    return dec

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
    ne = rows * cols
    x = np.random.default_rng(7).standard_normal((16, cols)).astype(np.float32)

    # base 4bit
    pcode, sc = quant_fp4_per128(ref)
    decE = decode_fp4_per128(pcode, sc, rows, cols, ngrp)
    base_bytes = rows * (ngrp + (cols + 1) // 2)

    resid = ref - decE
    print("tensor %s [%d,%d]  base4bit=%d B (%.3f bit/elem)" % (tname, rows, cols, base_bytes, 8*base_bytes/ne))
    print("%-8s %9s %10s %10s %8s %8s" % ("resid%", "bit/elem", "storageMB", "energy%", "SNR", "argmax%"))

    y_ref = x @ ref.T
    a_ref = np.argmax(y_ref, axis=1)
    base_same = (a_ref == np.argmax(x @ decE.T, axis=1)).mean()
    print("base 4bit alone            argmax %.2f%%" % (base_same*100))

    for k in (0, 6.25, 12.5, 16, 25, 50, 100):
        if k == 0:
            dec = decE.copy()
            cbytes = 0
        else:
            thr = np.percentile(np.abs(resid), 100 - k)
            gdec = resid * (np.abs(resid) > thr)
            gc, gs = quant_e8m7_128(gdec)
            gc = gc[:, :cols]
            gdec_full = decode_mxfp8_128(np.hstack([np.broadcast_to(gs[..., :ngrp], (rows, ngrp)), gc]), rows, cols, ngrp)
            dec = decE + gdec_full
            # 真正稀疏存储(行隐含, 值为 e8m7 码): 每非零 = 2B col-idx(uint16, cols≤65536) + 1B code
            #     每行一个 scale(int8, 8bit 残差行的最大幅值) = 1B/行
            nzcnt = int(np.count_nonzero(gc))
            cbytes = rows + nzcnt * 3
        tot = base_bytes + cbytes
        err = dec - ref
        nz = np.abs(ref) > 1e-30
        energy = np.sqrt((err[nz]**2).sum() / (ref[nz]**2).sum())
        snr = 20*np.log10(np.sqrt((ref[nz]**2).sum())/np.sqrt((err[nz]**2).sum())+1e-30)
        same = (a_ref == np.argmax(x @ dec.T, axis=1)).mean()
        print("%6.1f %9.3f %10.2f %10.2f %8.1f %8.2f" %
              (k, 8*tot/ne, tot/2**20, energy*100, snr, same*100))

main()