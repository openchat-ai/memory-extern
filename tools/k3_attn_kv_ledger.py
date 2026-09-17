#!/usr/bin/env python3
"""
K3 注意力 KV 字节账（第一账）—— 从 data/trunk.json 纯 shape 计算，不碰权重。
复现 Moonshot「线性注意力 KV 减 75%」声称的结构级验证。
2026-09-17 · 依据 sources/kimi_k3.py + 2026-08-29 真权重实测 shape
"""
import json, os, sys
from collections import Counter

TRUNK = os.path.join(os.path.dirname(__file__), "..", "data", "trunk.json")

def load():
    with open(TRUNK) as f:
        return json.load(f)

def classify_layer(ts):
    if any("kv_b_proj.weight" in n for n in ts):
        return "MLA"
    names = " ".join(ts.keys())
    if "q_proj.weight" in names and "v_proj.weight" in names and "k_proj.weight" in names:
        return "KDA"
    return "?"

def main():
    d = load()
    layers = d["layers"]
    sizes = []
    per_layer_weights = []  # 每层注意力权重字节(bf16→2 或 MXFP8→1 按真实 dtype)
    for i, l in enumerate(layers):
        ts = l["tensors"]
        k = classify_layer(ts)
        attn_bytes = 0
        for n, m in ts.items():
            if "self_attn." in n:
                elems = 1
                for s in m["shape"]:
                    elems *= s
                bpe = {"BF16": 2, "F16": 2, "F32": 4, "MXFP8_E8M7_128": 1,
                       "MXFP4": 1}.get(m["dtype"], 2)
                attn_bytes += elems * bpe
        per_layer_weights.append((i, k, attn_bytes))
        sizes.append((i, k, attn_bytes))

    c = Counter(k for _, k, _ in sizes)
    n_kda, n_mla = c["KDA"], c["MLA"]
    print(f"层分类: KDA={n_kda}  MLA={n_mla}  总 {n_kda+n_mla}")

    mla_idx = [i for i, k, _ in sizes if k == "MLA"]
    l0 = layers[mla_idx[0]]["tensors"]
    prefix = f"language_model.model.layers.{mla_idx[0]}.self_attn."
    kv_a = l0[prefix + "kv_a_proj_with_mqa.weight"]["shape"][0]   # 512 latent + 64 rope
    kv_b = l0[prefix + "kv_b_proj.weight"]["shape"][0]            # 24576 = kv_heads*(nope+v)
    q_b  = l0[prefix + "q_b_proj.weight"]["shape"][0]             # 18432 = q_heads*(nope+rope)
    q_a  = l0[prefix + "q_a_proj.weight"]["shape"][0]             # 1536 q_lora_rank
    print(f"MLA 层 {mla_idx[0]} 维度: kv_a={kv_a} (latent+rope)  kv_b_expand={kv_b}  "
          f"q_a={q_a}  q_b_expand={q_b}")
    print(f"  反推: 128-head 假设 → kv_b/128={kv_b//128} =kv-b heads·(nope+v); "
          f"q_b/128={q_b//128} q-heads·(rope+nope); rope=kv_a-kv_lora_rank")

    # KV cache per token per MLA layer (bf16 档 = 576 元素 × 2B)
    kv_vals_per_tok = kv_a                      # latent + rope, 每 token 缓存
    for dtype, bpe in (("BF16", 2), ("FP8", 1), ("MXFP4", 0.5)):
        b_tok = kv_vals_per_tok * bpe * n_mla   # 全模型每 token 新增 KV 字节
        m1m = b_tok * 1_000_000
        all_mla = kv_vals_per_tok * bpe * 93
        all_mla_1m = all_mla * 1_000_000
        print(f"\n[{dtype}] 每 token/层 KV 缓存 = {kv_vals_per_tok} 值 = "
              f"{kv_vals_per_tok*bpe} B")
        print(f"  K3 每 token (24 MLA 层) = {b_tok} B ≈ {b_tok/1024:.2f} KiB")
        print(f"  K3 @1M token = {m1m/1e9:.2f} GB")
        print(f"  同规模全 MLA (93 层) @1M = {all_mla_1m/1e9:.2f} GB")
        print(f"  省幅 = {1 - n_mla/93:.2%}  (结构账 {n_mla}/{93})")
        print(f"  → 每 token 缓存比 = {b_tok/(kv_vals_per_tok*bpe*93):.4f}")

    # KDA 固定状态账（不随序列增长）
    kda_state = 96 * 128 * 128 * 2  # bf16 状态/层
    print(f"\nKDA 固定状态 (不随序列增长): {kda_state} B/层 × 69 = {kda_state*69/1e6:.1f} MB")
    attn_total = sum(b for _, _, b in sizes)
    print(f"全部注意力权重 (部署字节, 按真实 dtype) = {attn_total/1e9:.2f} GB")

    # 注意力权重按层出
    print("\n每层注意力权重字节 (按 dtype):")
    for i, k, b in sizes:
        print(f"  L{i:2d} {k:3s} {b/1e6:8.1f} MB")

if __name__ == "__main__":
    main()