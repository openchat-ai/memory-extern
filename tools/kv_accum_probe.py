#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""kv_accum_probe.py - KV latent 逐 token 累积误差验证

问题: decode 时 KV cache 逐 token 追加。INT8 每 token 独立 scale 时,
量化误差是否随 cache 长度累积? 还是每行独立、保持恒定量级?
测试两种量化粒度:
  per-token(每 token 独立 scale, 板上 INT8 口径)     -> 预期: 不累积
  per-cache(整个 cache 共享 1 个 scale)              -> 预期: 随长度累积(scale 漂移)
用真实 layer3 权重 + 真实 x(可扩展 T)。report cache 长度 4..64 下
当前 query 的 attention argmax 保真 / 全 cache 的 score 误差。

用法: kv_accum_probe.py <layers_dir> <trunk_layers.json> <mla_layer_id> [--x-npy F] [--seq N]
"""
import json, math, sys
import numpy as np


def decode_tensor(lfb, t):
    raw = lfb[int(t["off"]):int(t["off"]) + int(t["nbytes"])]
    shape = [int(v) for v in t["shape"]]
    if len(shape) == 1:
        return np.frombuffer(raw, np.uint16).astype(np.float16).astype(np.float32)
    R, C = shape
    ngrp = int(t["ngrp"])
    packed = np.frombuffer(raw, np.uint8).reshape(R, ngrp + C)
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


def q_per_token(a):
    """每 token 独立 scale, 8bit。返回 float32 反量化。"""
    b = np.empty_like(a)
    for i in range(a.shape[0]):
        lo, hi = a[i].min(), a[i].max()
        if hi - lo < 1e-12:
            b[i] = a[i]; continue
        s = 255.0 / (hi - lo)
        q = np.clip(np.round((a[i] - lo) * s), 0, 255).astype(np.uint8)
        b[i] = q / s + lo
    return b


def q_per_cache(a):
    """整个 cache 共享 1 个 scale, 8bit。返回 float32 反量化。"""
    lo, hi = a.min(), a.max()
    if hi - lo < 1e-12:
        return a.copy()
    s = 255.0 / (hi - lo)
    q = np.clip(np.round((a - lo) * s), 0, 255).astype(np.uint8)
    return q / s + lo


def main():
    argv = sys.argv
    x_npy = None; seq = -1
    _argv = [argv[0]]; i = 1
    while i < len(argv):
        if argv[i] == "--x-npy": x_npy = argv[i+1]; i += 2
        elif argv[i] == "--seq": seq = int(argv[i+1]); i += 2
        else: _argv.append(argv[i]); i += 1
    argv = _argv
    trunk, layers_json, slot = argv[1], argv[2], int(argv[3])
    man = json.load(open(layers_json))
    lay = man["layers"][slot]
    lfb = open("%s/layer_%03d.bin" % (trunk, slot), "rb").read()
    T = "language_model.model.layers.%d." % slot

    kv_a = decode_tensor(lfb, lay["tensors"][T + "self_attn.kv_a_proj_with_mqa.weight"])
    kv_a_ln = decode_tensor(lfb, lay["tensors"][T + "self_attn.kv_a_layernorm.weight"])
    kv_b = decode_tensor(lfb, lay["tensors"][T + "self_attn.kv_b_proj.weight"])
    q_a = decode_tensor(lfb, lay["tensors"][T + "self_attn.q_a_proj.weight"])
    q_a_ln = decode_tensor(lfb, lay["tensors"][T + "self_attn.q_a_layernorm.weight"])
    q_b = decode_tensor(lfb, lay["tensors"][T + "self_attn.q_b_proj.weight"])

    E, qk_nope, qk_rope, vh, H = 7168, 128, 64, 128, 96

    if x_npy is not None:
        x = np.load(x_npy).astype(np.float32)
    else:
        rng = np.random.default_rng(7)
        x = rng.standard_normal((seq, E)).astype(np.float32)
        x = x / np.sqrt((x * x).mean(1, keepdims=True) + 1e-6)

    def rmsnorm(v, w):
        return v / np.sqrt((v * v).mean() + 1e-6) * w

    Tq = x.shape[0]
    q = rmsnorm(x @ q_a.T, q_a_ln) @ q_b.T
    q = q.reshape(Tq, H, 192).astype(np.float32)
    q_nope, q_rope = q[..., :128], q[..., 128:]
    ckv = x @ kv_a.T
    latent, k_rope = ckv[..., :512], ckv[..., 512:]
    latent = rmsnorm(latent, kv_a_ln)

    # ref 全精度 cache -> k/v
    kv = (latent @ kv_b.T).reshape(Tq, H, 256)
    k_nope, v = kv[..., :128], kv[..., 128:]
    krb = np.broadcast_to(k_rope[:, None, :], (Tq, H, 64))
    ks = np.concatenate([k_nope, krb], -1)                      # [T,H,192]
    qs = np.concatenate([q_nope, q_rope], -1)
    scale = 192 ** -0.5
    causal = np.tril(np.ones((Tq, Tq), bool))[:, None, :]

    print("x %s latent %s  seq=%d" % (x.shape, latent.shape, Tq), flush=True)

    def attention(qs, ks, v, causal):
        att = np.einsum("qhd,khd->qhk", qs, ks) * scale
        att = np.where(~causal, -np.inf, att)
        emax = att.max(-1, keepdims=True)
        p = np.exp(att - emax)
        p = p / p.sum(-1, keepdims=True)
        y = np.einsum("qhk,khv->qhv", p, v)
        return p, y

    pref_p, pref_y = attention(qs, ks, v, causal)
    a_ref = pref_p.argmax(-1)
    # 仅最后 query(最新 token) 的 argmax 最重要(decode)
    last_ref = a_ref[-1]

    print("\ncache 长度下, 最后 token argmax 保真 vs 全精度 (量化对象 = 前 L 行的 latent cache):")
    print("%-7s %-13s %-13s" % ("cacheL", "per-token%", "per-cache%"))
    for L in (4, 8, 16, 24, 32, 48, 64):
        if L > Tq:
            break
        lp = latent[:L]
        lq_pt = q_per_token(lp)
        lq_pc = q_per_cache(lp)
        res = {}
        for tag, lq in (("pt", lq_pt), ("pc", lq_pc)):
            kq = (lq @ kv_b.T).reshape(L, H, 256)
            knq, vq = kq[..., :128], kq[..., 128:]
            ks_l = np.concatenate([knq, np.broadcast_to(k_rope[:L, None, :], (L, H, 64))], -1)
            p, _ = attention(qs[-1:], ks_l, vq, causal[-1:, :, :L])
            same = int((p.argmax(-1)[0] == a_ref[-1]).sum()) / H * 100
            res[tag] = same
        print("%-7d %-13.1f %-13.1f" % (L, res["pt"], res["pc"]), flush=True)

    # 直接量化误差的累积检查: 每行 relative error
    err_pt = np.abs(q_per_token(latent) - latent) / (np.abs(latent) + 1e-30)
    err_pc = np.abs(q_per_cache(latent) - latent) / (np.abs(latent) + 1e-30)
    print("\nlatent 量化相对误差: per-token mean %.4f / per-cache mean %.4f"
          % (err_pt.mean(), err_pc.mean()))
    print("per-token 各行误差 std = %.4f (应~恒定, 不随行号增长)"
          % err_pt.mean(axis=1).std())


if __name__ == "__main__":
    main()