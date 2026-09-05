#!/usr/bin/env python3
"""mxfp8_pow2.py — MXFP8 二幂(尾数小)量化对比: e6m7(已量化)→MXFP8+熵再压 全链.

前提(用户已完成): BF16(e8m7)→e6m7(14bit) 量化, 熵=6.5bit 已确认.
本工具做后面工作: 用二幂法实现 8bit MXFP8, 并测"固定8bit vs 熵再压"的差距.

全链: e6m7(14bit) → MXFP8(E4M3, 8bit, 块尺2^e) → 熵编码再压(目标~6.5bit)

输出每配置:
  - 熵 (bit/权重): 熵压能达到的理论下限
  - 固定8bit vs 熵压bit 对比 (冗余量 = 8 - 熵)
  - 量化误差 (相对L2 / 最大误差)

用法:
  python3 mxfp8_pow2.py --safetensors <file> --tensor <name> [--block 32]
  python3 mxfp8_pow2.py --raw <bin> --dtype float32 --shape 7168,4096
"""
import argparse
import json
import math
import numpy as np

def quantize_range(vmin, vmax, E, bias):
    """返回能量化的指数指数范围 [emin,emax],校验可表示."""
    # 我们允许尾数 k ∈ 1..(1+2^M-1), 取最大线性量化步, 保证不溢出即可
    return None

def mxfp8_quantize(W, E, M, block=32):
    """W: (rows, cols) fp32. 逐块 scale + 每元素 2^e 阶量化.
    返回 (Wq, scales, stat).
    E>0: 每元素都有 e,bias=2^(E-1)-1; 尾数 M bit(0..M spec).
    这里按"每块共享 scale,每元素独立阶乘尾数"的 MXFP8 实现.
    """
    rows, cols = W.shape
    n = rows * cols
    Wq = np.zeros_like(W)
    scales = []
    bias = 2 ** (E - 1) - 1 if E >= 1 else 0
    max_mant = (1 << M) - 1   # 尾数能表示的最大整数: 0..2^M-1
    step = 2.0 ** (-M)        # 尾数步进(归一化)
    for r0 in range(0, rows, max(1, block)):
        for c0 in range(0, cols, max(1, block)):
            blk = W[r0:r0+block, c0:c0+block]
            amax = np.max(np.abs(blk)) if blk.size else 0
            if amax == 0:
                scales.append(0.0)
                continue
            # scale = 2^floor(log2(amax/ max_mant-ish)), 让最大块内值能表示
            # 简化: scale 取 2^s 使归一化后最大尾数≤max_mant
            s = math.floor(math.log2(amax)) - M + 1
            scale = 2.0 ** s if M >= 1 else 1.0
            if scale == 0:
                scale = 1.0
            scales.append(scale)
            # 量化每元素到 (idx, e)
            v = blk / scale
            # 尾数+指数: 归一化到 [1,2) 取指数
            mag = np.abs(v)
            # 若 mag 为0
            e = np.zeros_like(mag)
            mfrac = np.zeros_like(mag)
            nz = mag > 0
            if np.any(nz):
                e[nz] = np.floor(np.log2(mag[nz]))
                ei = np.clip(e.astype(np.int64) + bias, 0, 2 ** E - 1)
                # 尾数: m = round( (mag/2^e - 1) * max_mant )
                # 简化尾数为 0..max_mant
                norm = mag[nz] / (2.0 ** e[nz])
                mq = np.clip(np.round((norm - 1.0) * max_mant), 0, max_mant).astype(np.int64)
                val = scale * (1.0 + mq / max_mant) * (2.0 ** (ei - bias))
                Wq[r0:r0+block, c0:c0+block][nz] = val
    return Wq, np.array(scales, dtype=np.float32)

def mxfp8_pow2_quantize(W, E, M, block=32):
    """精确: 块尺度 scale(2的幂), 每元素 sign + 尾数(0..2^M-1) + 指数(0..2^E-1).
    返回 (Wq, per_weight_bits估算, stat dict)
    """
    rows, cols = W.shape
    n = rows * cols
    bias = 2 ** (E - 1) - 1
    max_mant = (1 << M) - 1
    Wq = np.zeros_like(W)
    nb_blocks = 0
    # 熵: 统计 (e,m,sign) 三元组频率
    from collections import Counter
    cnt = Counter()
    tot_weights = 0
    for r0 in range(0, rows, block):
        for c0 in range(0, cols, block):
            blk = W[r0:r0+block, c0:c0+block]
            amax = np.max(np.abs(blk)) if blk.size else 0.0
            nb_blocks += 1
            if amax == 0:
                for v in blk.flatten():
                    cnt[(0, 0, 0)] += 1
                    tot_weights += 1
                continue
            s = math.floor(math.log2(amax)) - M + 1
            scale = 2.0 ** s
            v = blk / scale
            mag = np.abs(v)
            e = np.full_like(mag, 0)
            nz = mag > 0
            if np.any(nz):
                e[nz] = np.floor(np.log2(mag[nz]))
            ei = np.clip(e.astype(np.int64) + bias, 0, 2 ** E - 1)
            norm = np.ones_like(mag)
            nzn = mag > 0
            if np.any(nzn):
                norm[nzn] = mag[nzn] / (2.0 ** e[nzn])
            mq = np.clip(np.round((norm - 1.0) * max_mant), 0, max_mant).astype(np.int64)
            rec = scale * (1.0 + mq / max_mant) * (2.0 ** (ei - bias))
            sn = (v < 0).astype(np.int64)
            # 写回
            idx0 = (mq, ei, sn)
            Wq[r0:r0+block, c0:c0+block] = np.where(nz, rec, 0.0) * np.where(v >= 0, 1, -1)
            for mm, ee, ss in zip(mq.flatten(), ei.flatten(), sn.flatten()):
                cnt[(int(ee), int(mm), int(ss))] += 1
                tot_weights += 1
    # 熵
    probs = np.array(list(cnt.values()), dtype=np.float64) / max(1, tot_weights)
    entropy = -np.sum(probs * np.log2(probs + 1e-30))
    return Wq, entropy, nb_blocks

def report(name, W, Wq, entropy, nblocks, block):
    err = np.linalg.norm(W - Wq) / np.linalg.norm(W)
    maxerr = np.max(np.abs(W - Wq))
    save = 8 - entropy          # 熵压相对固定8bit能省的量
    print(f"  {name}: 熵={entropy:.2f} bit/权重  相对L2误差={err:.4f}  最大误差={maxerr:.4g}")
    print(f"      固定8bit={8.0:.0f} → 熵压={entropy:.2f}  (省 {save:.2f}bit/权重, "
          f"{save/8*100:.1f}% 存储冗余可熵压挤掉)")
    return {"config": name, "entropy": entropy, "rel_l2": err, "max_err": maxerr}

def run_for(W, E, M, block, tag):
    Wq, ent, nb = mxfp8_pow2_quantize(W, E, M, block)
    return report(tag, W, Wq, ent, nb, block)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw")
    ap.add_argument("--safetensors")
    ap.add_argument("--tensor")
    ap.add_argument("--dtype", default="float32")
    ap.add_argument("--shape", help="如 7168,4096")
    ap.add_argument("--block", type=int, default=32)
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
    elif args.raw:
        W = np.fromfile(args.raw, dtype=args.dtype)
        if args.shape:
            W = W.reshape(tuple(int(x) for x in args.shape.split(",")))
    else:
        ap.print_help(); return
    W = np.asarray(W, dtype=np.float32)
    print(f"权重: shape={list(W.shape)} 元素={W.size:,}")

    configs = [  # (E, M, 名称)
        (6, 1, "e6m1 (纯二幂 k∈{1,3})"),
        (5, 2, "e5m2 (k∈{1,3,5})"),
        (4, 3, "e4m3 (k∈{1,3,5,7}, 近NVFP8)"),
    ]
    results = []
    for E, M, name in configs:
        r = run_for(W, E, M, args.block, name)
        results.append(r)
    print("\n[对比]")
    best = min(results, key=lambda r: r["entropy"] + r["rel_l2"] * 30)
    for r in results:
        mark = "  ←" if r is best else ""
        print(f"  {r['config']}: 熵{r['entropy']:.2f}bit  误差{r['rel_l2']:.4f}{mark}")
    print(f"\n→ 推荐(熵+误差加权最优): {best['config']}")

if __name__ == "__main__":
    main()