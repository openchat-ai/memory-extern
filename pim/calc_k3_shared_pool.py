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
CLOCK_GHZ      = 1.0      # 满档（prefill/突发）
DIE_COST       = 91       # 14nm die+封装+PHY（量产）

# ===== 用户可调频率 (超频) =====
import argparse
_p = argparse.ArgumentParser(description="K3 共享池：用户可自定 MAC 频率（超频/降压）")
_p.add_argument("--freq", type=float, default=None, nargs="+",
                help="MAC 频率 GHz。默认 = DRAM 匹配档（~0.134，省电）；"
                     "超频示例: --freq 0.5 / 1.0 可对比满档")
args = _p.parse_args()

K3_MAC_PER_TOKEN = 1.12e11   # 每token MACs（trunk 1.48e10 + 专家 9.72e10）
TOTAL_MAC = N_CHIPS * MAC_PER_CHIP

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

# ===== 频率匹配档（DRAM 瓶颈 → MAC 降到刚好够吃的频率）=====
F_MATCH_GHZ = TPS_K3 * K3_MAC_PER_TOKEN / (TOTAL_MAC * 1e9)   # GHz

def calc_power(freq_ghz):
    """对齐 calc_performance.py 功耗模型（单颗）：
       MAC_POWER=38W@1GHz(f³) + 漏电2W + SRAM2 + SerDes2 + 其他1 = 静态7W
       动态随频率降, 静态(漏电)不降"""
    mac_dyn = 38.0 * N_CHIPS * (freq_ghz / 1.0) ** 3
    static = (2 + 2 + 2 + 1) * N_CHIPS
    return mac_dyn + static

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

# ===== 功耗/超频 (用户可调 --freq) =====
print(f"\n--- 功耗 / 超频 (--freq {args.freq or '默认匹配档'}) ---")
print(f"  DRAM 匹配档: MAC 最低频率 = {F_MATCH_GHZ*1000:.0f} MHz (P∝f³, 省电)")
print(f"  满档:        1.0 GHz (prefill/突发 = 100 档)")

freqs = args.freq if args.freq else [F_MATCH_GHZ, 0.5, 1.0]
print(f"  {'频率':>8} {'算力TMAC/s':>10} {'MAC功耗W':>9} {'总功耗W':>8} {'vs匹配':>7} {'速度影响':>10}")
for f in freqs:
    tmac = TOTAL_MAC * f / 1e3
    pw = calc_power(f)
    speedup = f / F_MATCH_GHZ
    need = TPS_K3 * K3_MAC_PER_TOKEN / 1e12
    if tmac >= need * 1.05:
        note = "DRAM瓶颈"
    elif tmac >= need * 0.95:
        note = "平衡≈匹配档"
    else:
        note = "MAC瓶颈←算力不足"
    print(f"  {f:>7.3f}GHz {tmac:>10.2f} {pw:>8,.0f}W {pw:>6,.0f}W {speedup:>6.2f}x {note:>10}")
print(f"  ↑ 匹配档仅是长期解码稳态频率；超频不提升稳态(K3受DRAM限), 但拉高prefill突发算力")

# ===== PCB 面积预算 v2 (28-bank 近存) =====
print(f"\n--- PCB 面积预算 v2 (28 bank × 8die合封 + 1 LPDDR) ---")
die_area = 5.6
bank_pkg = 8 * die_area * 1.6
lpddr_die = 100.0
bank_total = bank_pkg + lpddr_die
area_banks = 28 * bank_total
extra = 2000 + 500 + 700 + 1200
CARD = 33384
tot = area_banks + extra
print(f"  每bank: 8die合封 {bank_pkg:.0f}mm² + LPDDR {lpddr_die:.0f}mm² = {bank_total:.0f}mm²")
print(f"  28 bank = {area_banks:,.0f}mm² + 走线/PCIe/电源 {extra}mm² = {tot:,.0f}mm²")
print(f"  卡 {CARD:,}mm² 占用 {tot/CARD*100:.1f}%  ✅")
print(f"  功耗: 匹配档 ≈{calc_power(F_MATCH_GHZ):,.0f}W / 满档 ≈{calc_power(1.0):,.0f}W (见上方超频档)")

print(f"\n{'='*70}")
print(f"结论: ¥{new_total/1e4:.1f}万 / {TPS_K3:.1f}t/s ≈ H200 / 1/{(290*1e4)/new_total:.0f} 成本")
print(f"{'='*70}")
