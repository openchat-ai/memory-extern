#!/usr/bin/env python3
"""
kv_capacity_plan.py — KV-Cache 分层容量规划器（§14 前置）

背景（config.json 实测 2026-08-26，回填 T2）：
  K3 为 MLA 架构：hidden=7168，层数 93，
  kv_lora_rank=512，qk_rope_head_dim=64，num_heads=96，
  num_key_value_heads=96（全 KV，无 GQA 压缩）。
  MLA 下 KV 每 token/层 = kv_lora_rank + qk_rope_head_dim × num_heads
                        = 512 + 64×96 = 6656 元素（≈全注意力 12288 的 54%）

核心方程：
  kv_mb_per_tok = L × (kv_lora_rank + qk_rope_head_dim×num_heads) × bytes
  预算 tok      = ddr_gb×1024 / kv_mb_per_tok
  注意力读取带宽 = ctx × kv_mb_per_tok / token   （与 25.83GB 权重流量对比）

用法：
  python3 kv_capacity_plan.py                    # 全场景扫描（MLA 定案口径）
  python3 kv_capacity_plan.py --ddr-gb 2         # 指定板载容量
"""

import argparse

LAYERS   = 93
HIDDEN   = 7168
WEIGHT_GB_TOK = 25.83          # 实测权重流量（每生成 token 必付）
KV_LORA   = 512                 # MLA latent 秩（config kv_lora_rank）
ROPE_DIM  = 64                  # MLA qk_rope_head_dim
NUM_HEADS = 96                  # MLA num_heads（= num_key_value_heads）
# MLA KV 每 token 元素数 = latent + rope×heads
MLA_KV_DIM = KV_LORA + ROPE_DIM * NUM_HEADS  # = 6656


def kv_mb_per_tok(dtype: str) -> float:
    bytes_e = {"fp16": 2.0, "q8": 1.0, "q4": 0.5}[dtype]
    return LAYERS * MLA_KV_DIM * bytes_e / 1e6


def plan(ddr_gb: float):
    print(f"\n板载 DDR = {ddr_gb} GB | 权重流量固定 {WEIGHT_GB_TOK} GB/tok\n"
          f"MLA: kv_lora={KV_LORA} + rope({ROPE_DIM}×{NUM_HEADS}头) = "
          f"{MLA_KV_DIM} 元素/tok/层\n")

    print(f"{'dtype':>5} | " + " ".join(f"{d:>7}" for d in ("fp16", "q8", "q4")))
    print("-" * 46)

    row = []
    for dtype in ("fp16", "q8", "q4"):
        mb = kv_mb_per_tok(dtype)
        row.append(f"{int(ddr_gb*1024/mb):>7}")
    print(f"{'tok':>5} | " + " ".join(row))
    print("       ↑ 单元：全预算可容纳的上下文 token 数（batch=1）")

    # batch×ctx 运行点（Q8 口径）
    print(f"\nQ8 口径 · batch×最大上下文 运行点：")
    print(f"{'batch':>6} | {'ctx_tok':>8}")
    print("-" * 18)
    mb = kv_mb_per_tok("q8")
    for b in (1, 4, 8, 16, 32, 64):
        print(f"{b:>6} | {int(ddr_gb*1024/mb/b):>8}")

    # KV 读带宽 vs 权重流量的交叉点
    print(f"\n注意力 KV 读带宽交叉点（超过此 ctx 后 KV 读开始挤占权重带宽）：")
    mb = kv_mb_per_tok("q8")
    cross_ctx = WEIGHT_GB_TOK * 1e3 / mb
    print(f"  MLA  kv={mb:.2f}MB/tok → 交叉 ctx ≈ {cross_ctx:,.0f}")

    print(f"""
结论模板：
  · KV【容量】是硬约束 → 由 (kv_heads=96, MLA, dtype, batch, ctx) 决定准入
  · MLA 使 KV 比全注意力小 46%（6656 vs 12288 元素/tok/层）
  · KV【读带宽】在 ctx<数千 时远小于权重流量 → 不是瓶颈
  · 超预算的溢出去向：主机内存(batch 模式) / NVMe(独立模式,延迟翻倍代价) /
    直接降 batch —— 准入控制器按本表自动选运行点
""")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ddr-gb", type=float, default=1.0)
    args = ap.parse_args()
    plan(args.ddr_gb)
