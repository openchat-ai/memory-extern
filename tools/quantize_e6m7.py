#!/usr/bin/env python3
"""quantize_e6m7.py — 先决条件: BF16(e8m7,16bit)→e6m7(14bit) 量化 + 熵测量.

用户明确: e6m7(14bit) 是前提, 不是直接跳 8bit MXFP8.
BF16 = e8m7 (1符号+8指数+7尾数, 16bit)
e6m7 = 1符号+6指数+7尾数 (14bit), 即把指数从 8 砍到 6 (动态范围 -4x~+4x), 尾数保留 7.

步骤:
  1. 读权重(FP32/BF16)
  2. 量化到 e6m7 (指数截断到 6bit, re-bias=31; 溢出/下溢饱和)
  3. 测量:
     - 熵 (bit/权重): 信息量, 对应"6.5bit"目标
     - 相对L2误差 / 最大误差: 质量
     - 压缩对比: 原始16bit vs 14bit vs 实际熵bit

用法:
  python3 quantize_e6m7.py --safetensors <file> --tensor <name>
  python3 quantize_e6m7.py --raw <bin> --dtype float32 --shape 7168,4096
"""
import argparse
import json
import math
import numpy as np
from collections import Counter

def to_e6m7(W):
    """W(fp32 array) → 量化到 e6m7(1符号+6指数+7尾数). 返回 (Wq, stats).
    尾数7bit 存 8bit 有效(隐式1), 实际 mantissa 7bit → ULP=2^-7.
    指数6bit, bias=31, 范围 e∈[-31,32]. e8m7 是 bias=127 范围[-127,128].
    所以 e6m7 是更窄的动态范围, 大/小极端值会饱和/下溢.
    """
    W = np.asarray(W, dtype=np.float32)
    sign = np.signbit(W).astype(np.int8)
    mag = np.abs(W)
    # 指数: e = floor(log2(mag)) + bias
    nz = mag > 0
    e = np.zeros(mag.shape, dtype=np.float32)
    e[nz] = np.floor(np.log2(mag[nz]))
    # e6m7: bias=31, e 截到[0,63]
    bias = 31
    ei = np.clip(e + bias, 0, 63)
    # 尾数: m = round( (mag/2^e - 1) * 2^7 ), 7bit
    norm = np.ones(mag.shape, dtype=np.float32)
    norm[nz] = mag[nz] / (2.0 ** e[nz])
    mant = np.clip(np.round((norm - 1.0) * 128.0), 0, 127)
    # 重建
    rec = np.zeros_like(mag)
    ok = (ei >= 0) & (ei <= 63)
    rec[ok] = (1.0 + mant[ok] / 128.0) * (2.0 ** (ei[ok] - bias))
    Wq = np.where(sign, -rec, rec)
    # 零保持零
    Wq[~nz] = 0.0
    # 溢出/下溢统计
    overflow = ((e + bias) > 63) & nz
    underflow = ((e + bias) < 0) & nz
    stats = {
        "overflow_frac": overflow.mean(),
        "underflow_frac": underflow.mean(),
    }
    return Wq.astype(np.float32), stats

def measure(W, Wq):
    rel = np.linalg.norm(W - Wq) / np.linalg.norm(W)
    maxerr = np.max(np.abs(W - Wq))
    return rel, maxerr

def entropy_of(Wq):
    """统计(符号,指数,尾数)三元组的熵(bit/权重)."""
    Wq = np.asarray(Wq, dtype=np.float32)
    mag = np.abs(Wq)
    sign = (Wq < 0).astype(np.int64)
    # 压缩: 对非零取指数+尾数索引; 零单独
    nz = mag > 0
    cnt = Counter()
    # 零
    n_zero = int((~nz).sum())
    if n_zero:
        cnt[(0, -1, -1)] += n_zero
    # 非零
    nzn = mag[nz]
    if nzn.size:
        e = np.floor(np.log2(nzn)).astype(np.int64)
        norm = nzn / (2.0 ** e)
        m = np.round((norm - 1.0) * 128.0).astype(np.int64)
        s = sign[nz]
        for ee, mm, ss in zip(e, m, s):
            cnt[(int(ss), int(ee), int(mm))] += 1
    total = Wq.size
    probs = np.array(list(cnt.values()), dtype=np.float64) / total
    ent = -np.sum(probs * np.log2(probs + 1e-30))
    return ent

def report(name, W, Wq, stats):
    rel, maxerr = measure(W, Wq)
    ent = entropy_of(Wq)
    print(f"\n=== {name} ===")
    print(f"  量化到 e6m7(14bit): 相对L2误差={rel:.5f}  最大误差={maxerr:.4g}")
    print(f"  熵(bit/权重) = {ent:.2f}   (目标参考 6.5)")
    print(f"  溢出(饱和){stats['overflow_frac']*100:.3f}%  下溢(归零){stats['underflow_frac']*100:.3f}%")
    print(f"  原始16bit={W.size*16/1e6:.1f}Mb → 14bit={W.size*14/1e6:.1f}Mb → 熵码≈{W.size*ent/1e6:.1f}Mb")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--safetensors")
    ap.add_argument("--tensor")
    ap.add_argument("--raw")
    ap.add_argument("--dtype", default="float32")
    ap.add_argument("--shape")
    args = ap.parse_args()

    if args.safetensors:
        import sys; sys.path.insert(0, "tools")
        from probe_real_weights import read_bf16_as_f32
        with open(args.safetensors, "rb") as f:
            nb = int.from_bytes(f.read(8), "little")
            hdr = json.loads(f.read(nb))
            doff = 8 + nb
            d = hdr[args.tensor]
            o0, o1 = d["data_offsets"]
            nn = int(np.prod(d["shape"]))
            f.seek(doff + o0)
            if d["dtype"] == "BF16":
                W = read_bf16_as_f32(f, nn).reshape(d["shape"])
            else:
                W = np.frombuffer(f.read(o1 - o0), dtype=np.float32).reshape(d["shape"])
        name = args.tensor
    elif args.raw:
        W = np.fromfile(args.raw, dtype=args.dtype)
        if args.shape:
            W = W.reshape(tuple(int(x) for x in args.shape.split(",")))
        name = args.raw
    else:
        ap.print_help(); return
    W = np.asarray(W, dtype=np.float32)
    Wq, stats = to_e6m7(W)
    report(name, W, Wq, stats)

if __name__ == "__main__":
    main()