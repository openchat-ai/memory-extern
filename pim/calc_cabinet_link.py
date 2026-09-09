#!/usr/bin/env python3
"""calc_cabinet_link.py — 移动柜全数据通路账 (L1硬盘→L5对外IO)

把 calc_k3_shared_pool.py 的"池墙/MAC墙"扩展到柜子全集：
  L1 硬盘→池   换模型带宽 (组织级, 非每token)
  L2 池→MAC    每token权重读墙 (已有, 复用)
  L3 图执行器↔池 互联PCIe 墙 (柜内控制/路由GEMV搬运)
  L4 结果写回   MAC→池 与 输出缓冲 (GP字宽)
  L5 对外IO    SFP+/GbE 输入输出 (用户→柜→用户)

KV cache 账 (K3 MLA 特性):
  K3 = 93层 = 69 KDA(定长状态 S_t, 无KV) + 24 Gated-MLA(有KV, latent 512+64)
  ⇒ 只有24层存KV, 每token存 576 维 latent (BF16 1.15KB/token/层)
  ⇒ 1M (1048576) context: 24×1.15KB = 27.6MB/token/层... 全token叠加:
     24层的 latent 总量 = 1M tokens × 24 × 1152B = 28.3GB — 池内, 不占L3.
  再压缩到 int8: 减半 14.1GB.

数据源(有出处, 不拍脑袋):
  - 层结构:    docs/k3/ARCHITECTURE_BASELINE.md §1.2 (69/24/1 block末尾) + §4.1
  - latent:    ≥_dims_data.md line 103 (kv latent 512 content+64 rope)
  - 池墙/MAC墙: calc_k3_shared_pool.py walls() 复用口径
  - 流量:      trunk 55.6GB MXFP8 + 专家 25.83GB/token (每 token 81.43GB)
  - FPGA财经:  Tang 138K Pro PCIe3.0 x4 ≈ 2.95GB/s 有效 (calc_fpga_occupancy.py pcie_bw)
  - 对外IO:    SFP+ 2×10GbE = 2.5GB/s; GbE 0.125GB/s
"""
import sys
import argparse

# ───────── 1. K3 架构常量 (ARCHITECTURE_BASELINE / head_dims_data) ─────────
K3 = dict(
    layers=93,
    kda_layers=69,            # 定长状态, 无 KV 缓存
    mla_layers=24,            # Gated-MLA, 每 token 存 latent
    latent_dim=576,           # 512 content + 64 rope (kv_a_proj 576)
    trunk_gb=55.6,            # trunk_mxfp8.bin
    expert_gb_per_tok=25.83,  # 专家每token读
    hidden=7168,
    router_n=896,             # 路由专家数
    router_topk=16,
    mac_per_tok=1.12e11,      # 每token MAC
)

# ───────── 2. 带宽常量 (与已有脚本一致) ─────────
# LPDDR5X 每 die(16bit通道) 21.3GB/s @10667MT/s (chip-count-calculation.md)
MEM_GB_PER_DIE = 8
BWS_PER_DIE = 21.3           # GB/s 每 16bit lane (非 171: 那是整 8ch 子系统)
PCIEX4 = 2.95                # GB/s PCIe x4 有效 (FPGA 板上)
SFP20G = 2.5                 # GB/s 2×10GbE 全双工 (SFP+ 理论 2.5GB/s, 保守 0.8→2.0)
GBE    = 0.125               # GB/s 1GbE
NVME   = 30.0                # GB/s NVMe Gen5 (换模型用)

# ───────── 3. KV cache / latent 账 ─────────
def kv_byte_per_token(layers, dim, bytes_per_dim=2):
    """MLA latent 缓存: 每 token 每层存 dim 维 latent."""
    return layers * dim * bytes_per_dim

def kv_gb_for_ctx(nctx, layers=K3["mla_layers"]):
    """给定 context 长度, 所有 MLA 层的 latent 总字节(GB).
    KDA 层无 KV, 只有 24 MLA 层存 latent. """
    per_tok = kv_byte_per_token(layers, K3["latent_dim"])
    return nctx * per_tok / 1e9

# ───────── 4. 池墙 / MAC墙 (复用 K3 shared_pool 口径) ─────────
def pool_wall(pool_gb):
    n_dies = pool_gb / MEM_GB_PER_DIE
    bw = n_dies * BWS_PER_DIE
    return bw / (K3["trunk_gb"] + K3["expert_gb_per_tok"])

def mac_wall(n_mac):
    return n_mac * 128e9 / K3["mac_per_tok"]

# ───────── 5. 柜子主流程 ─────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", type=int, default=1024, help="池 LPDDR GB")
    ap.add_argument("--mac", type=int, default=256, help="MAC 颗数")
    ap.add_argument("--ctx", type=int, default=1_048_576, help="KV context (默认1M)")
    ap.add_argument("--tps", type=float, default=None, help="实际吞吐 t/s (默认=池墙)")
    args = ap.parse_args()

    t_ldd = pool_wall(args.pool)
    t_mac = mac_wall(args.mac)
    tps = args.tps or min(t_ldd, t_mac)

    print("=" * 72)
    print("移动柜全数据通路账")
    print("=" * 72)
    print(f"  池 {args.pool}GB / MAC {args.mac}颗 / ")
    print(f"  池墙 = {t_ldd:.1f} t/s   MAC墙 = {t_mac:.1f} t/s   "
          f"实际 = {tps:.1f} t/s")

    # 每 token 流量
    per_tok = K3["trunk_gb"] + K3["expert_gb_per_tok"]
    print(f"\n-- 每 token 权重读 {per_tok:.2f}GB (trunk {K3['trunk_gb']} + 专家 {K3['expert_gb_per_tok']})")

    # L1 硬盘→池 (换模型)
    print(f"\n-- L1 硬盘→池 (NVMe {NVME}GB/s) --")
    print(f"  冷模型 {per_tok:.0f}GB 全量入池 ≈ {per_tok/NVME:.0f}s ; 组织级, 非每token")
    l1 = NVME / per_tok
    print(f"  若每 token 都要换模型(不现实): {l1:.2f} t/s — 只影响模型切换频率")

    # L2 池墙
    print(f"\n-- L2 池→MAC (LPDDR 墙) --")
    print(f"  池带宽 = {args.pool/MEM_GB_PER_DIE*BWS_PER_DIE/1024:.2f} TB/s → {t_ldd:.1f} t/s")
# L3 互联
    print(f"\n-- L3 图执行器↔池 (PCIe x4 {PCIEX4}GB/s) --")
    # router 权重 [896×7168]; 若 FPGA 端持有一份 → 每 token 从池搬权重来算
    router_b = K3["router_n"] * K3["hidden"] * 2          # BF16 12.85MB/层
    router_int8 = K3["router_n"] * K3["hidden"] * 1       # int8 6.4MB/层
    layers_router = K3["layers"] - 1                      # 92 路由层 (末层无)
    print(f"  router 权重 [896×7168] = {router_b/1e6:.2f}MB/层 (BF16) / {router_int8/1e6:.2f}MB (int8)")
    print(f"  × {layers_router} 路由层 = {router_b*layers_router/1e9:.2f}GB (BF16) 每 token")
    g_b = router_b * layers_router / 1e9
    g_i = router_int8 * layers_router / 1e9
    print(f"  ── 口径 A: router 权重留池内, 由 MAC 算 (calc_fpga_occupancy T3 修正) ──")
    print(f"     FPGA 只收路由结果 top16 + 每层 hidden 状态 → 每 token ~{7168*2*layers_router/1e6:.2f}MB")
    l3A = PCIEX4 / (7168*2*layers_router/1e9)
    print(f"     ⇒ 互联墙 {l3A:,.0f} t/s — 富余, 不用搬权重")
    print(f"  ── 口径 B: router 权重驻留 FPGA, 每 token 从池搬 ──")
    print(f"     BF16 {g_b:.2f}GB/token → 互联墙 {PCIEX4/g_b:.1f} t/s ; int8 {g_i:.2f}GB → {PCIEX4/g_i:.1f} t/s")
    print(f"     ⇒ 死墙 — 图执行器绝不能持有 router 权重, 必须池内算")

    # L4 结果写回
    print(f"\n-- L4 KV/结果写回 (池内) --")
    kv_b = kv_byte_per_token(K3["mla_layers"], K3["latent_dim"])      # 27KB/token
    kv_bw = kv_b * tps / 1e9                                          # 写回带宽 GB/s
    pw = args.pool / MEM_GB_PER_DIE * BWS_PER_DIE / 1000              # 池总带宽 TB/s
    print(f"  KV latent: {K3['mla_layers']}层 × {K3['latent_dim']}dim × 2B = {kv_b/1024:.1f} KB/token")
    print(f"  @ {tps:.0f}t/s 写回带宽 {kv_bw:.3f}GB/s = 池带宽 {pw:.2f}TB/s 的 {kv_bw/pw*100:.2f}% — 非墙")

    # L5 对外
    print(f"\n-- L5 对外 IO (SFP+ 2×10GbE {SFP20G:.1f}GB/s / GbE {GBE}GB/s) --")
    out_b = K3["hidden"] * 2                                # token 输出嵌入 14.3KB
    print(f"  token 输出嵌入 {out_b/1e3:.1f}KB → SFP+ 上限 {SFP20G/(out_b/1e6):.0f}k token/s "
          f"(远超 {tps:.1f}t/s)")
    print(f"  GbE 输入 {GBE*1e6/out_b:.0f}k token/s — 请求/输出均富余, 非墙")

    # L6 BPE tokenizer (表驱动, 非FSM)
    print(f"\n-- L6 BPE tokenizer (词表 160K, ARCHITECTURE_BASELINE §1) --")
    vocab = 160_000
    merges = 159_999
    bpe_table = vocab * 32 + merges * 8          # 词元表 32B/词 + merge pair 8B
    print(f"  词表 {vocab:,} + merge {merges:,} → 表 {bpe_table/1e6:.0f}MB (放 DDR3, 表驱动)")
    print(f"  查找引擎 LUT ~6K (哈希查表), 每 token 输出 = 1 token 但输入瞬态仅 ~KB 级,")
    print(f"  DDR3 表读带宽 5.3GB/s 撑 {5.3e9/4:.0f} tok/s, 非墙 (BPE 查表)")

    # KV 端
    print(f"\n-- KV cache 总账 (MLA latent, KDA 无) --")
    ctx_tok = args.ctx
    for dtype, b in [("BF16", 2), ("INT8", 1)]:
        g = kv_gb_for_ctx(ctx_tok, K3["mla_layers"]) * b / 2
        print(f"  {dtype:5s} context {ctx_tok:,} tokens: {g:.1f} GB (24 MLA层 latent)")

    # 池里放得下吗
    kv_g = kv_gb_for_ctx(ctx_tok)
    print(f"  KV {kv_g:.1f}GB vs 池 {args.pool}GB: "
          f"{'✅ 池内全驻留(注意 55.6GB trunk 也占)' if kv_g < args.pool else '⚠️ KV 超池, 要流式'}")

if __name__ == "__main__":
    main()