#!/usr/bin/env python3
"""
kv_capacity_plan.py — KV-Cache 存储规划器（2026-09-10 实证定案口径）

架构事实（研究闭环, K3_KV_QUANT_PROBE.md + kv_quant_probe.py 实证）：
  K3 93 层中只有 24 层是 MLA/v2（idx 3,7,...,91,92）, 其余 69 层是 KDA/v1（无 KV cache）。
  MLA 每 token 写回 = latent 512 + 共享 rope 64 = 576 元素/层（mqa rope 96 头共享一份,
  不是 64×96=6656 —— 旧口径错在把 rope 当每头一份）。
  板上写回（decode 每 token / prefill 每 chunk）:
    BF16 latent   : 576 × 2B × 24 = 27.6KB/token
    INT8 latent   : 512 × 1B × 24 = 12.3KB/token   （实证 argmax 99%, E 8.6%）
    + rope 4bit   : 64 × 0.5B × 24 = 0.77KB/token  （实证 0 损失）
    => INT8+rope4 : 13.06KB/token (footprint 减半, 甜点)
  KV 读带宽随 ctx 增长; 写回走板→主机 FIFO(append-only), 不进板上 DDR。

用法:
  python3 kv_capacity_plan.py                    # 默认主机 KV 预算 1GB 工况
  python3 kv_capacity_plan.py --kv-gb 2          # 指定可分配给 KV 的内存
"""

import argparse

MLA_LAYERS = 24            # 24 层 MLA（v2）, 其余 69 层 KDA 无 KV cache
KV_LORA    = 512           # latent 秩（kv_lora_rank）
ROPE_DIM   = 64            # 共享 rope（qk_rope_head_dim, 96 头共享一份）
KV_ELEM    = KV_LORA + ROPE_DIM  # = 576 写回元素/层/token


def kv_bytes_per_tok(scheme: str) -> float:
    """每 token 写回字节（24 层合计, 层内 latent + rope 分档）"""
    if scheme == "bf16":
        return MLA_LAYERS * (KV_LORA + ROPE_DIM) * 2.0
    if scheme == "int8":
        return MLA_LAYERS * KV_LORA * 1.0 + MLA_LAYERS * ROPE_DIM * 1.0
    if scheme == "int8_r4":   # latent INT8 + rope 4bit（实证甜点）
        return MLA_LAYERS * KV_LORA * 1.0 + MLA_LAYERS * ROPE_DIM * 0.5
    raise KeyError(scheme)


def plan(kv_gb: float):
    schemes = [("bf16", "BF16 全量"), ("int8", "INT8 全量"), ("int8_r4", "INT8+rope4bit")]
    print(f"\nKV 预算 = {kv_gb} GB（24 层 MLA · per-token 写回 latent512+共享rope64）")
    print(f"{'方案':<16} | {'写回/token':>10} | {'可容上下文':>12}")
    print("-" * 44)
    ntoks = {"bf16": 0, "int8": 0, "int8_r4": 0}
    for key, name in schemes:
        b = kv_bytes_per_tok(key)
        ntoks[key] = kv_gb * 1024**3 / b
        print(f"{name:<16} | {b/1024:>7.2f}KB | {ntoks[key]:>12,.0f}")
    print(f"\nINT8+rope4  vs BF16: 同预算上下文 {ntoks['int8_r4']/ntoks['bf16']:.2f}x")
    print(f"""
结论:
  · 板上写回预算约束由 token 数决定, INT8+rope4 把同预算上下文推 {ntoks['int8_r4']/ntoks['bf16']:.2f}x
  · KV 走板→主机 FIFO(append-only), 不进板上 DDR; 主机按本表定 pinned 区大小
  · 8K→16K: KV 预算翻倍或 INT8 减半 —— 不碰权重流量(25.83GB/token 是硬账)
""")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--kv-gb", type=float, default=1.0)
    args = ap.parse_args()
    plan(args.kv_gb)