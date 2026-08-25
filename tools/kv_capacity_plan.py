#!/usr/bin/env python3
"""
kv_capacity_plan.py — KV-Cache 分层容量规划器（§14 前置）

背景（k3-verdict.md 实测）：
  hidden=7168，层数 93；GQA 头数未确认 → 本工具把 kv_heads 参数化，
  config.json 确认后跑一次即得真数。

核心方程：
  kv_mb_per_tok = L × 2(K+V) × hidden/kv_group × bytes
  预算 tok      = ddr_gb×1024 / kv_mb_per_tok
  注意力读取带宽 = ctx × kv_mb_per_tok / token   （与 25.83GB 权重流量对比）

用法：
  python3 kv_capacity_plan.py                    # 全场景扫描
  python3 kv_capacity_plan.py --kv-heads 8       # config 确认后定点计算
"""

import argparse

LAYERS   = 93
HIDDEN   = 7168
WEIGHT_GB_TOK = 25.83          # 实测权重流量（每生成 token 必付）
HEAD_DIM = 128                  # 常规假设：kv_dim = kv_heads × head_dim


def kv_mb_per_tok(kv_heads: int, dtype: str) -> float:
    kv_dim = min(kv_heads * HEAD_DIM, HIDDEN)
    bytes_e = {"fp16": 2.0, "q8": 1.0, "q4": 0.5}[dtype]
    return LAYERS * 2 * kv_dim * bytes_e / 1e6


def plan(ddr_gb: float):
    print(f"\n板载 DDR3 = {ddr_gb} GB | 权重流量固定 {WEIGHT_GB_TOK} GB/tok\n")

    print(f"{'kv头数':>7} {'等效kv维':>8} | " +
          " ".join(f"{d:>7}" for d in ("fp16", "q8", "q4")))
    print("-" * 46)

    for kvh in (1, 2, 4, 8, HIDDEN // HEAD_DIM):     # GQA 扫描
        row = []
        for dtype in ("fp16", "q8", "q4"):
            mb = kv_mb_per_tok(kvh, dtype)
            row.append(f"{int(ddr_gb*1024/mb):>7}")
        kvdim = min(kvh * HEAD_DIM, HIDDEN)
        print(f"{kvh:>7} {kvdim:>8} | " + " ".join(row))
    print("       ↑ 单元：全预算可容纳的上下文 token 数（batch=1）")

    # batch×ctx 运行点（Q8 口径）
    print(f"\nQ8 口径 · batch×最大上下文 运行点：")
    print(f"{'batch':>6} | " + " ".join(f"kv头={k:<4}" for k in (1, 4, 8)))
    print("-" * 34)
    for b in (1, 4, 8, 16, 32, 64):
        row = []
        for kvh in (1, 4, 8):
            mb = kv_mb_per_tok(kvh, "q8")
            row.append(f"{int(ddr_gb*1024/mb/b):>5}")
        print(f"{b:>6} | " + " ".join(f"{r:>7}" for r in row))

    # KV 读带宽 vs 权重流量的交叉点
    print(f"\n注意力 KV 读带宽交叉点（超过此 ctx 后 KV 读开始挤占权重带宽）：")
    for kvh, tag in ((1, "MHA最坏"), (8, "GQA÷16")):
        mb = kv_mb_per_tok(kvh, "q8") / 1.0
        cross_ctx = WEIGHT_GB_TOK * 1e3 / mb
        print(f"  {tag:<10} kv={mb:.2f}MB/tok → 交叉 ctx ≈ {cross_ctx:,.0f}")

    print(f"""
结论模板：
  · KV【容量】是硬约束 → 由 (kv_heads, dtype, batch, ctx) 四元组决定准入
  · KV【读带宽】在 ctx<数千 时远小于权重流量 → 不是瓶颈
  · 超预算的溢出去向：主机内存(batch 模式) / NVMe(独立模式,延迟翻倍代价) /
    直接降 batch —— 准入控制器按本表自动选运行点
""")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--ddr-gb", type=float, default=1.0)
    args = ap.parse_args()
    plan(args.ddr_gb)
