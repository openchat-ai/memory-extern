#!/usr/bin/env python3
"""
K3 共享池架构 · 真实 BOM + 吞吐
2026-09-07 定案：226GB 共享 LPDDR5X 池，224颗子计算单元共享
对比旧假设（128GB/颗 × ¥8/GB 便宜内存口径）
"""
# ===== K3 实测参数 (k3-verdict.md + MoE-token-speed.md) =====
K3_EXPERT_PER_TOKEN_GB = 25.83   # 92层×16experts×17.55MB
K3_TRUNK_PER_TOKEN_GB  = 113.49  # fp16，100%必读，不可缓存
K3_TOTAL_PER_TOKEN_GB  = K3_EXPERT_PER_TOKEN_GB + K3_TRUNK_PER_TOKEN_GB  # 139.32

# ===== 共享池容量 (lpddr-resident-architecture.md 226GB档) =====
POOL_GB        = 226.0
TRUNK_GB       = 55.0     # trunk 驻留（减半口径）
EXPERT_POOL_GB = POOL_GB - TRUNK_GB  # 171GB = 工作集专家（10,010对×17.55MB）

# ===== 芯片参数 (calculation-formulas.md) =====
N_CHIPS        = 224
MAC_PER_CHIP   = 128
CLOCK_GHZ      = 1.0
DIE_COST       = 91       # 14nm die+封装+PHY（量产）

# ===== 内存参数 =====
LPDDR_PRICE_OLD = 8       # ¥/GB（旧便宜假设）
LPDDR_PRICE_NEW = 60      # ¥/GB（LPDDR5X 实际）
LPDDR_PER_CHIP_OLD = 128  # GB（旧：每颗独立128GB）
MEM_GB_PER_DIE  = 8        # GB（新：共享池 226GB = 28颗 8GB）
N_MEM_DIES      = POOL_GB / MEM_GB_PER_DIE

# ===== 带宽计算 =====
BWS_PER_DIE = 171.0        # 8ch LPDDR5X GB/s
POOL_BW     = N_MEM_DIES * BWS_PER_DIE
H200_BW     = 4800.0

# ===== 吞吐 =====
TPS_K3      = POOL_BW / K3_TOTAL_PER_TOKEN_GB
TPS_H200    = H200_BW / K3_TOTAL_PER_TOKEN_GB

# ===== 成本 =====
# 旧口径（每颗独立含内存）
old_mem_total = N_CHIPS * LPDDR_PER_CHIP_OLD * LPDDR_PRICE_OLD
old_chip_cost = N_CHIPS * (DIE_COST + LPDDR_PER_CHIP_OLD * LPDDR_PRICE_OLD + 59)  # +杂费凑1174
old_total     = old_chip_cost

# 新口径（共享池）
new_mem_cost  = POOL_GB * LPDDR_PRICE_NEW
new_chip_cost = N_CHIPS * DIE_COST
new_pcb       = 800
new_total     = new_chip_cost + new_mem_cost + new_pcb

# ===== 输出 =====
print("=" * 70)
print("K3 共享池架构 · 真实 BOM + 吞吐 对照")
print("=" * 70)

print(f"\n--- K3 模型 ---")
print(f"  专家/token : {K3_EXPERT_PER_TOKEN_GB} GB")
print(f"  trunk/token: {K3_TRUNK_PER_TOKEN_GB} GB")
print(f"  合计/token : {K3_TOTAL_PER_TOKEN_GB} GB")

print(f"\n--- 共享池 {POOL_GB:.0f}GB (trunk {TRUNK_GB:.0f} + 工作集专家 {EXPERT_POOL_GB:.0f}) ---")
print(f"  形态: {N_MEM_DIES:.0f}颗 {MEM_GB_PER_DIE}GB LPDDR5X")
print(f"  池带宽: {N_MEM_DIES:.0f}×{BWS_PER_DIE:.0f} = {POOL_BW:,.0f} GB/s")

print(f"\n--- 吞吐 ---")
print(f"  K3 共享池: {TPS_K3:.1f} t/s")
print(f"  H200 单卡: {TPS_H200:.1f} t/s")
print(f"  相对: {TPS_K3/TPS_H200:.2f}x")

print(f"\n--- 旧口径（每颗独立128GB × ¥8/GB）---")
print(f"  内存: 224×128GB×¥8 = ¥{old_mem_total:>10,.0f} = {old_mem_total/1e4:.1f}万")
print(f"  整卡: 224×¥1,174  = ¥{old_total:>10,.0f} = {old_total/1e4:.1f}万")

print(f"\n--- 新口径（226GB共享池 × ¥60/GB）---")
print(f"  芯片: 224×¥{DIE_COST}  = ¥{new_chip_cost:>10,.0f} = {new_chip_cost/1e4:.1f}万")
print(f"  内存: {POOL_GB:.0f}GB×¥{LPDDR_PRICE_NEW} = ¥{new_mem_cost:>10,.0f} = {new_mem_cost/1e4:.1f}万")
print(f"  PCB等:             = ¥{new_pcb:>10,}  = {new_pcb/1e4:.1f}万")
print(f"  整卡:              = ¥{new_total:>10,.0f} = {new_total/1e4:.1f}万")
print(f"  vs H200 ¥290万    = 1/{(290*1e4)/new_total:.0f}")

print(f"\n--- 内存成本对比 ---")
print(f"  旧: 224×128×¥8  = ¥{old_mem_total:>10,.0f} = {old_mem_total/1e4:.1f}万")
print(f"  新: 226×¥60     = ¥{new_mem_cost:>10,.0f} = {new_mem_cost/1e4:.1f}万")
print(f"  净省: ¥{old_mem_total-new_mem_cost:>10,.0f} = {(old_mem_total-new_mem_cost)/1e4:.1f}万")
print(f"  原因: 单价×7.5 但总量缩 {old_mem_total/new_mem_cost:.0f}倍 → 内存反省 {(1-new_mem_cost/old_mem_total)*100:.0f}%")

print(f"\n{'='*70}")
print(f"结论: ¥{new_total/1e4:.1f}万 / {TPS_K3:.1f}t/s ≈ H200 / 1/{(290*1e4)/new_total:.0f} 成本")
print(f"{'='*70}")
