#!/usr/bin/env python3
"""importance_score.py — 列重要性 index 实验（notes/importance-index-onboarding.md §3.2）

裁决量①：K3 专家 w1/w2/w3 的列重要性集中度。实测判死（top50%=50.6%≈均匀）。

score 口径:
  base : score[j] = sum_i |W[i,j]|                （免激活基线）
  act  : score[j] = sum_i |W[i,j]| * E|x_j|       （激活加权；E|x_j| 来自引擎探针
          K3_EXPECT_DUMP 输出的 expect.txt，见 notes）

MXFP4 解包（notes/k3_pack_format.md）:
  packed [out, in/2] U8: 2 nibble/byte, low=even, high=odd
  scale  [out, in/32] U8: E8M0, value = E2M1[nib] * 2^(scale-127); scale==255 -> 0

用法:
  python3 importance_score.py L1[,L2..] E1[,E2..] w1,w2,w3 [expect.txt]
  # expect.txt 存在时输出 base+act 两口径；否则只输出 base
"""
import json, math, sys
import numpy as np
from safetensors import safe_open

E2M1 = np.array([0.0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 6.0,
                -0.0, -0.5, -1.0, -1.5, -2.0, -3.0, -4.0, -6.0], dtype=np.float32)

IDX = "/model/model.safetensors.index.json"


def load_index(idx=IDX):
    with open(idx) as f:
        return json.load(f)["weight_map"]


def key(L, E, mat, suffix, wm):
    return f"language_model.model.layers.{L}.block_sparse_moe.experts.{E}.{mat}.{suffix}"


def read_expect(path):
    """parse expect.txt: # z_abs n=... then # act_abs n=..."""
    z, act = None, None
    cur = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line.startswith("# z_abs"):
                cur = z = []
            elif line.startswith("# act_abs"):
                cur = act = []
            elif line:
                cur.append(float(line))
    return (np.array(z, dtype=np.float32) if z else None,
            np.array(act, dtype=np.float32) if act else None)


def dequant_matrix(packed, scale):
    """packed [out, in/2] U8 + scale [out, in/32] U8 -> W [out, in] fp32"""
    out, in2 = packed.shape
    in_dim = in2 * 2
    v_even = E2M1[packed & 0x0F]
    v_odd = E2M1[(packed >> 4) & 0x0F]
    p = np.arange(in2, dtype=np.int64)
    g = p // 16  # element 2p (or 2p+1) lives in scale group (2p)//32 == p//16
    mul = np.take(scale, g, axis=1)
    mul = np.where(mul == 255, 0.0, np.power(2.0, mul.astype(np.float32) - 127.0))
    W = np.empty((out, in_dim), dtype=np.float32)
    W[:, 0::2] = v_even * mul
    W[:, 1::2] = v_odd * mul
    return W


def report(name, sc, in_dim):
    order = np.argsort(sc)[::-1]
    total = sc.sum()
    parts = []
    for keep in (0.3, 0.5, 0.7):
        k = int(keep * in_dim)
        parts.append(f"top{keep*100:.0f}%={sc[order[:k]].sum()/total:.4f}")
    print(f"  [{name}] max={sc.max():.3e} min={sc.min():.3e} mean={sc.mean():.3e} "
          f"std={sc.std():.3e} " + " ".join(parts))


def main():
    wm = load_index()
    Ls = [int(x) for x in sys.argv[1].split(",")]
    Es = [int(x) for x in sys.argv[2].split(",")]
    mats = sys.argv[3].split(",") if len(sys.argv) > 3 else ["w1", "w2", "w3"]
    expect = read_expect(sys.argv[4]) if len(sys.argv) > 4 else (None, None)
    z, act = expect
    if z is not None:
        print(f"E|z|   len={len(z)} cv={z.std()/z.mean():.4f}")
        print(f"E|act| len={len(act)} cv={act.std()/act.mean():.4f}")
    for L in Ls:
        for E in Es:
            for mat in mats:
                pkey = key(L, E, mat, "weight_packed", wm)
                skey = key(L, E, mat, "weight_scale", wm)
                with safe_open(f"/model/{wm[pkey]}", framework="np") as sf:
                    packed = sf.get_slice(pkey)[:]
                    scale = sf.get_slice(skey)[:]
                W = dequant_matrix(packed, scale)
                in_dim = W.shape[1]
                sc_base = np.abs(W).sum(axis=0)
                print(f"L{L}.E{E}.{mat} in={in_dim}")
                report("base", sc_base, in_dim)
                if z is not None:
                    xm = z if mat in ("w1", "w3") else act
                    if xm is not None and xm.shape[0] == in_dim:
                        report("act", (np.abs(W) * xm[None, :]).sum(axis=0), in_dim)


if __name__ == "__main__":
    main()