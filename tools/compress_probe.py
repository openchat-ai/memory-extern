#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""compress_probe.py - 单张量"不解压可用"压缩研究

研究对象: v1 层4 routed_expert_up_proj [7168,3584] (MXFP8_E8M7_128, 层切片内)
流程: 从已切出的 layer 切片解码回 F32 → 对每个候选格式重量化 → 报告:
      bit/elem, 存储体积, maxabs/rel/SNR vs BF16, argmax 保真(随机0均值高斯输入)。

候选格式(全部硬件直读, 无解码物化):
  A  MXFP8_E8M7_128 现状     8.0625 bit/elem   (现有 k3_matmul_e8m7_128)
  B  MXFP4 E2M1+E8M7/128     4.0625 bit/elem   (scale 沿用 per-128, 4bit 码)
  C  MXFP4 近邻映射 per-128  4.0625 bit/elem   (最靠近的 E2M1 值)
  D  2:4 稀疏 + MXFP4        2.0625 bit/elem   (结构剪枝, 跳零 FMA)
  E  MXFP4 + E8M0/128 scale  4.0625 bit/elem   (E2M1 码 + 128分组 E8M0 幂次)

用法: compress_probe.py <trunk_dir> <layers.json> <layer_id> <tensor_name>
"""
import json, math, sys
import numpy as np

E2M1 = np.array([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0,
                 -0.0, -0.5, -1.0, -1.5, -2.0, -3.0, -4.0, -6.0], dtype=np.float32)
# E2M1 positive magnitudes
E2M1_POS = np.array([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0], dtype=np.float32)

def bf16_to_f32(u16):
    return (u16.astype(np.uint32) << 16).view(np.float32)

def entropy_bits(a):
    c = np.bincount(a.astype(np.int64).ravel())
    c = c[c > 0].astype(np.float64)
    p = c / c.sum()
    return float(-(p * np.log2(p)).sum())

def report(tag, bits_elem, storage, dec, ref, x):
    err = dec - ref
    scale = np.max(np.abs(ref))
    nz = np.abs(ref) > 1e-30
    rel = np.max(np.abs(err)[nz]) / scale
    energy = np.sqrt((err[nz] ** 2).sum() / (ref[nz] ** 2).sum())
    snr = 20 * np.log10(np.sqrt((ref[nz] ** 2).sum()) / np.sqrt((err[nz] ** 2).sum()) + 1e-30)
    # argmax 保真: y = W x, 比较 top-1 列序
    y_ref = x @ ref.T
    y_dec = x @ dec.T
    a_ref = np.argmax(y_ref)
    a_dec = np.argmax(y_dec)
    same = float((np.argmax(y_ref, 1) == np.argmax(y_dec, 1)).mean())
    print("  %-28s %7.3f bit/elem   %9.2f MB   maxrel %8.1e   energy %7.2f%%   "
          "SNR %5.1f dB   argmax命中 %6.2f%%"
          % (tag, bits_elem, storage / 2**20, rel, energy * 100, snr, same * 100))


def decode_mxfp8_128(packed, rows, cols, ngrp):
    stride = ngrp + cols
    dec = np.zeros((rows, cols), np.float32)
    for r in range(rows):
        row = packed[r].ravel()
        scales = row[:ngrp]
        codes = row[ngrp:]
        for g in range(ngrp):
            e = int(scales[g]); e = e - 256 if e >= 128 else e
            gscale = math.ldexp(1.0, e - 6)
            lo, hi = g * 128, min((g + 1) * 128, cols)
            seg = codes[lo:hi]
            mag = (seg & 0x7F).astype(np.float32)
            neg = (seg >> 7).astype(np.float32)
            dec[r, lo:hi] = np.where(neg == 1, -mag, mag) * gscale
    return dec

def quant_e8m7_128(f32, group=128):
    """返回 MXFP8_E8M7_128 布局, 同 trunk2mxfp8.py. (rows,cols)"""
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

def decode_mxfp4_127(scale, codes, rows, cols, ngrp):
    """4bit 码 + per-128 E8M7 scale. codes: (rows, 2*cols) nibble-packed. col_even = low"""
    dec = np.zeros((rows, cols), np.float32)
    for r in range(rows):
        for g in range(ngrp):
            e = int(np.int8(scale[r, g]))
            gscale = math.ldexp(1.0, e - 6)
            lo, hi = g * 128, min((g + 1) * 128, cols)
            b = codes[r]
            lo2 = lo // 2
            hi2 = (hi + 1) // 2
            nib = b[lo2:hi2]
            E = np.zeros((hi - lo), np.uint8)
            E[0::2] = nib & 0x0F
            E[1::2] = (nib >> 4) & 0x0F
            dec[r, lo:hi] = E2M1[E] * gscale
    return dec

def quant_fp4_per128(f32, group=128):
    """MXFP4-style: 每 128 一组, 组内对数 scale, 码字取 E2M1 最近邻.
    返回 (pcode (rows,ceil(cols/2)), scale_e (rows,ngrp)).
    E2M1 值域 [0,6]; 归一化到组内 max 处接近 6, 小值取对数间隔 → 分布正确."""
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
        e_d[nz] = np.floor(np.log2(amax[nz] / 6.0))   # 最大 E2M1=6
    e_d = np.clip(e_d, -127, 127)
    e_i = e_d.astype(np.int8)
    sc2 = np.exp2(e_d)
    nm = (blocks.astype(np.float64) / sc2[:, :, None]).reshape(R, W)  # [0,6]
    E2 = E2M1_POS  # 0,0.5,1,1.5,2,3,4,6
    idx = np.abs(E2[None, None, :] - nm[..., None]).argmin(axis=-1)
    idx = idx[:, :C]
    neg = (f32 < 0).astype(np.uint8)
    ni = (idx & 0x07) | (neg << 3)          # 4-bit index: 3bit value + 1bit sign
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
    trunk = sys.argv[1]
    layers_json = sys.argv[2]
    li = int(sys.argv[3])
    tname = sys.argv[4]

    man = json.load(open(layers_json))
    lay = man["layers"][li]
    t = lay["tensors"][tname]
    fn = "%s/layer_%03d.bin" % (trunk, li)
    raw = open(fn, "rb").read()
    rows, cols = int(t["shape"][0]), int(t["shape"][1])
    ngrp = int(t["ngrp"])
    off = int(t["off"])
    expect = rows * (ngrp + cols)
    print("expect bytes", expect, "actual nbytes", int(t["nbytes"]))
    slice_bytes = raw[off: off + int(t["nbytes"])]
    stride = ngrp + cols
    packed = np.frombuffer(slice_bytes, np.uint8).reshape(rows, stride)
    ref = decode_mxfp8_128(packed, rows, cols, ngrp)
    ne = rows * cols
    x = np.random.default_rng(7).standard_normal((64, cols)).astype(np.float32)

    print("tensor %s [%d, %d], elems %.1fM" % (tname, rows, cols, ne / 1e6))
    print("%-28s %8s %10s %8s %8s %8s %8s" %
          ("scheme", "bit/elem", "storage", "maxrel", "energy", "SNR", "argmax"))

    # A: MXFP8 现状(编码解码往返=开销基准)
    dec_A = ref
    report("A MXFP8_E8M7_128 (现状)", 8.0625, rows * stride, dec_A, ref, x)

    # E: MRL base-only —— per-128 对数归一 E2M1, 4.06 bit/elem (27.8GB 全trunk口径)
    pcodeE, scE = quant_fp4_per128(ref)
    decE = decode_fp4_per128(pcodeE, scE, rows, cols, ngrp)
    nbytes_E = rows * (ngrp + (cols + 1) // 2)
    report("E MRL base4bit E2M1+p128", 8.0 * nbytes_E / ne, nbytes_E, decE, ref, x)

    # F: MRL base(4bit E2M1/p128) + resid(8bit E8M7/p128)  —— 分级读, 全读 = 近 MXFP8
    rr, cc = ref.shape
    resid = ref - decE
    rcodes, rsc = quant_e8m7_128(resid)
    rcodes = rcodes[:, :cc]
    rdec = decode_mxfp8_128(np.hstack([np.broadcast_to(rsc[..., :ngrp], (rr, ngrp)), rcodes]), rr, cc, ngrp)
    decF = decE + rdec
    nbytes_F = rows * (ngrp + (cols + 1) // 2) + rows * (ngrp + cols)
    report("F MRL 4bit+resid8bit", 8.0 * nbytes_F / ne, nbytes_F, decF, ref, x)

    # G: MRL base(4bit) + resid(8bit) 稀疏 50% (只存大残差)
    thr = np.percentile(np.abs(resid), 50)
    gdec = resid * (np.abs(resid) > thr)
    gcodes, gsc = quant_e8m7_128(gdec)
    gcodes = gcodes[:, :cc]
    gdec_full = decode_mxfp8_128(np.hstack([np.broadcast_to(gsc[..., :ngrp], (rr, ngrp)), gcodes]), rr, cc, ngrp)
    nbytes_G = rows * (ngrp + (cols + 1) // 2) + (rows * (ngrp + cols)) // 2
    report("G MRL 4bit+sparse50%resid", 8.0 * nbytes_G / ne, nbytes_G, decE + gdec_full, ref, x)

    # H: MRL base(4bit E2M1) + resid(4bit 均匀 per-row)
    #   残差近似正态: 每行 ri = min + step*idx, step=(max-min)/15, 4bit 均匀
    rmin = resid.min(axis=1, keepdims=True)
    rmax = resid.max(axis=1, keepdims=True)
    rstep = (rmax - rmin) / 15.0
    rstep = np.where(rstep == 0, 1e-9, rstep)
    ridx = np.clip(np.round((resid - rmin) / rstep), 0, 15).astype(np.uint8)
    ph = np.zeros((rr, (cc + 1) // 2), np.uint8)
    ev, od = ridx[:, 0::2], ridx[:, 1::2]
    m2 = min(ev.shape[1], od.shape[1])
    ph[:, :m2] = ev[:, :m2] | (od[:, :m2] << 4)
    if cc % 2 == 1:
        ph[:, -1] = ev[:, -1]
    # decode
    rloop = np.zeros((rr, cc), np.float32)
    for r in range(rr):
        idxr = np.concatenate([ph[r, :cc // 2].astype(np.uint16) & 0x0F,
                               (ph[r, :cc // 2].astype(np.uint16) >> 4) & 0x0F])
        if cc % 2:
            idxr = np.concatenate([idxr, (ph[r, -1].astype(np.uint16) & 0x0F)])
        rloop[r] = rmin[r] + rstep[r] * idxr[:cc]
    decH = decE + rloop
    nbytes_H = rows * (ngrp + (cols + 1) // 2) + rows * 2 + (rows * (cc + 1) // 2)
    report("H MRL 4bit+uniform4bit", 8.0 * nbytes_H / ne, nbytes_H, decH, ref, x)

    # I: MRL base(4bit) + resid 只存 top-12.5%(98%能量阈值) —— 逼近极限压缩
    thr2 = np.percentile(np.abs(resid), 87.5)
    idec = resid * (np.abs(resid) > thr2)
    icodes, isc = quant_e8m7_128(idec)
    icodes = icodes[:, :cc]
    idec_full = decode_mxfp8_128(np.hstack([np.broadcast_to(isc[..., :ngrp], (rr, ngrp)), icodes]), rr, cc, ngrp)
    nbytes_I = rows * (ngrp + (cols + 1) // 2) + (rows * (ngrp + cols)) // 8
    report("I MRL 4bit+sparse12.5%resid", 8.0 * nbytes_I / ne, nbytes_I, decE + idec_full, ref, x)

main()