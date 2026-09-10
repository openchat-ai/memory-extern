#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""kv_quant_probe.py - K3 MLA latent(KV cache)量化容限研究

用户方向: KV 存'小矩阵'(latent 512+rope64)而非展开大KV -> 上下文长度放大。
本脚本验证拆小后, 再对 latent 量化(BF16/INT8/E2M1-4bit)对注意力保真的影响:
  - K(进 attention score) 容限 vs V(进加权和) 容限是否一致
  - 输出 score 的 argmax 保持率（硬指标, 类似权重研究的 argmax 命中）
  - 输出 y 的 energy 误差 / SNR
用真实 MLA 权重（从层切片 MXFP8 解码）, x=T×7168 真实形状。

用法: kv_quant_probe.py <layers_dir> <trunk_layers.json> <mla_layer_id>
"""
import json, math, sys
import numpy as np


def decode_tensor(lfb, t):
    """从层切片按 t=manifest张量记录解码 MXFP8 到 float32。
    布局: [rows][scales ngrp][codes cols]"""
    raw = lfb[int(t["off"]):int(t["off"]) + int(t["nbytes"])]
    shape = [int(v) for v in t["shape"]]
    if len(shape) == 1:
        return np.frombuffer(raw, np.uint16).astype(np.float16).astype(np.float32)
    assert len(shape) == 2, shape
    R, C = shape
    ngrp = int(t["ngrp"])
    packed = np.frombuffer(raw, np.uint8).reshape(R, ngrp + C)
    W = ngrp * 128
    dec = np.zeros((R, C), np.float32)
    for r in range(R):
        row = packed[r]
        sc, co = row[:ngrp], row[ngrp:]
        for g in range(ngrp):
            e = int(sc[g]); e = e - 256 if e >= 128 else e
            gs = math.ldexp(1.0, e - 6)
            lo, hi = g * 128, min((g + 1) * 128, C)
            seg = co[lo:hi]
            mag = (seg & 0x7F).astype(np.float32)
            neg = (seg >> 7).astype(np.float32)
            dec[r, lo:hi] = np.where(neg == 1, -mag, mag) * gs
    return dec


# ---- latent 量化器 ----
def quant_bf16(a):
    return a.astype(np.float16).astype(np.float32)


def quant_int8(a):
    """per-token per-layer scalar: 整行 min/max -> 256 级。返回量化+反量化。"""
    b = a.copy()
    for i in range(a.shape[0]):
        row = a[i]
        lo, hi = row.min(), row.max()
        if hi - lo < 1e-12:
            continue
        s = 255.0 / (hi - lo)
        q = np.clip(np.round((row - lo) * s), 0, 255).astype(np.uint8)
        b[i] = q / s + lo
    return b


def quant_int4_row(a):
    """4bit 每行线性量化: 每 token 1个 scale 覆盖整行, 16 级。返回量化+反量化。"""
    b = a.copy()
    for i in range(a.shape[0]):
        row = a[i]
        lo, hi = row.min(), row.max()
        if hi - lo < 1e-12:
            continue
        s = 15.0 / (hi - lo)
        q = np.clip(np.round((row - lo) * s), 0, 15).astype(np.uint8)
        b[i] = q / s + lo
    return b


def onehot_error(pred, ref):
    return int((pred.argmax(-1) == ref.argmax(-1)).sum())


def main():
    argv = sys.argv
    x_npy = None
    _argv = [argv[0]]
    i = 1
    while i < len(argv):
        if argv[i] == "--x-npy":
            x_npy = argv[i + 1]
            i += 2
        else:
            _argv.append(argv[i])
            i += 1
    argv = _argv
    trunk, layers_json, slot = argv[1], argv[2], int(argv[3])
    man = json.load(open(layers_json))
    lay = man["layers"][slot]
    lfb = open("%s/layer_%03d.bin" % (trunk, slot), "rb").read()
    T = "language_model.model.layers.%d." % slot

    kv_a = decode_tensor(lfb, lay["tensors"][T + "self_attn.kv_a_proj_with_mqa.weight"])   # [576, 7168]
    kv_a_ln = decode_tensor(lfb, lay["tensors"][T + "self_attn.kv_a_layernorm.weight"])     # [512]
    kv_b = decode_tensor(lfb, lay["tensors"][T + "self_attn.kv_b_proj.weight"])             # [24576, 512]
    q_a = decode_tensor(lfb, lay["tensors"][T + "self_attn.q_a_proj.weight"])               # [1536+?]
    print("kv_a %s kv_a_ln %s kv_b %s" % (kv_a.shape, kv_a_ln.shape, kv_b.shape), flush=True)
    print("q_a %s" % (q_a.shape,))

    # K3 真实维度
    E = 7168
    qk_nope, qk_rope, vh = 128, 64, 128
    H = 96
    QLORA = 1536
    q_a_ln = decode_tensor(lfb, lay["tensors"][T + "self_attn.q_a_layernorm.weight"])       # [1536]
    q_b = decode_tensor(lfb, lay["tensors"][T + "self_attn.q_b_proj.weight"])               # [18432, 1536]
    print("q_a_ln %s q_b %s" % (q_a_ln.shape, q_b.shape))

    if x_npy is not None:
        x = np.load(x_npy).astype(np.float32)
        Tq = x.shape[0]
        if x.shape[0] == 1:
            x = np.repeat(x, 4, axis=0)      # 单 token 展开成 4, 让因果注意有上下文
            Tq = x.shape[0]
        print("using REAL hidden-state x: %s, Tq=%d" % (x_npy, Tq), flush=True)
    else:
        rng = np.random.default_rng(7)
        # 模拟 T=64 真实形状隐藏态(每行 RMS=1 贴近层层归一后的真实量级; 权重真)
        Tq = 64
        x = rng.standard_normal((Tq, E)).astype(np.float32)
        x = x / np.sqrt((x * x).mean(axis=1, keepdims=True) + 1e-6)

    def rmsnorm(v, w):
        return v / np.sqrt((v * v).mean() + 1e-6) * w

    q = rmsnorm(x @ q_a.T, q_a_ln) @ q_b.T
    q = q.reshape(Tq, H, qk_nope + qk_rope).astype(np.float32)
    q_nope, q_rope = q[..., :qk_nope], q[..., qk_nope:]
    ckv = x @ kv_a.T
    latent, k_rope = ckv[..., :512], ckv[..., 512:]
    latent = rmsnorm(latent, kv_a_ln)
    print("q %s latent %s k_rope %s" % (q.shape, latent.shape, k_rope.shape), flush=True)

    # ref: 全精度注意力输出 + cache
    kv = (latent @ kv_b.T).reshape(Tq, H, qk_nope + vh)
    k_nope, v = kv[..., :qk_nope], kv[..., qk_nope:]
    k_rope_b = np.broadcast_to(k_rope[:, None, :], (Tq, H, qk_rope))
    qs = np.concatenate([q_nope, q_rope], -1)          # [T,H,192]
    ks = np.concatenate([k_nope, k_rope_b], -1)
    scale = (qk_nope + qk_rope) ** -0.5
    att = np.einsum("qhd,khd->qhk", qs, ks) * scale            # [T,H,T]
    causal = np.tril(np.ones((Tq, Tq), bool))[:, None, :]
    att = np.where(~causal, -np.inf, att)
    emax = att.max(-1, keepdims=True)
    p = np.exp(att - emax)
    p = p / p.sum(-1, keepdims=True)
    y = np.einsum("qhk,khv->qhv", p, v).reshape(Tq, H * vh)
    a_ref = p.argmax(-1)
    print("\nref attention done. argmax over %d tokens x %d heads" % (Tq, H), flush=True)

    print("\n%-12s %9s %10s %10s %8s %8s" % ("scheme", "bit/elem", "E-energy%", "SNR", "argmax%", "V-onlyE%"))
    schemes = [("BF16", quant_bf16, 16), ("INT8-sc", quant_int8, 8), ("INT4-row", quant_int4_row, 4)]
    for name, qfn, bits in schemes:
        lq = qfn(np.ascontiguousarray(latent))
        kqp = lq @ kv_b.T
        kqp = kqp.reshape(Tq, H, qk_nope + vh)
        knq, vq = kqp[..., :qk_nope], kqp[..., qk_nope:]
        ksq = np.concatenate([knq, k_rope_b], -1)
        attq = np.einsum("qhd,khd->qhk", qs, ksq) * scale
        attq = np.where(~causal, -np.inf, attq)
        emax = attq.max(-1, keepdims=True)
        pq = np.exp(attq - emax); pq = pq / pq.sum(-1, keepdims=True)
        yq = np.einsum("qhk,khv->qhv", pq, v).reshape(Tq, H * vh)
        # V-only: latent 量化, 但 K 恢复用精确(保 score) -> 隔离 V 误差
        # 用 ref attention p 和量化 v
        yv = np.einsum("qhk,khv->qhv", p, vq).reshape(Tq, H * vh)
        nz = np.abs(y) > 1e-30
        energy = np.sqrt(((yq - y)[nz] ** 2).sum() / (y[nz] ** 2).sum())
        snr = 20 * np.log10(np.sqrt((y[nz] ** 2).sum()) / np.sqrt(((yq - y)[nz] ** 2).sum()) + 1e-30)
        same = onehot_error(pq, p) / p.shape[0] / p.shape[1] * 100
        eVonly = np.sqrt(((yv - y)[nz] ** 2).sum() / (y[nz] ** 2).sum())
        print("%-12s %7.2f  %10.2f %10.1f %8.1f %8.2f" % (name, bits * 576 / 576, energy * 100, snr, same, eVonly * 100), flush=True)

    # rope 独立容限: latent 精确, 仅 k_rope 量化
    print("\n--- k_rope(64, 共享96头) 独立量化容限 ---")
    for name, qfn, bits in (("rope-INT8", quant_int8, 8), ("rope-INT4", quant_int4_row, 4)):
        krq = qfn(np.ascontiguousarray(k_rope))                      # [Tq, 64]
        krq_b = np.broadcast_to(krq[:, None, :], (Tq, H, qk_rope))
        ksq = np.concatenate([k_nope, krq_b], -1)
        attq = np.einsum("qhd,khd->qhk", qs, ksq) * scale
        attq = np.where(~causal, -np.inf, attq)
        emax = attq.max(-1, keepdims=True)
        pq = np.exp(attq - emax); pq = pq / pq.sum(-1, keepdims=True)
        same = onehot_error(pq, p) / p.shape[0] / p.shape[1] * 100
        yq = np.einsum("qhk,khv->qhv", pq, v).reshape(Tq, H * vh)
        nz = np.abs(y) > 1e-30
        energy = np.sqrt(((yq - y)[nz] ** 2).sum() / (y[nz] ** 2).sum())
        print("%-12s %7.2f bit/elem(K=%s,V=%s)  E-energy%5.2f%%  argmax %5.1f%%" %
              (name, (8 * 512 + bits * 64) / 576, "8", "16", energy * 100, same), flush=True)


main()