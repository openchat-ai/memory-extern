#!/usr/bin/env python3
"""GEMV 芯片晶体管估算 - 14nm FinFET (中芯国际) - 修正版"""
import math

print("=" * 60)
print("GEMV 芯片晶体管估算 - 14nm FinFET (修正版)")
print("=" * 60)

# ===== 1. 内存带宽决定 MAC 数 =====
# LPDDR5X: 16-bit channels, 8533 MT/s per pin
# 每通道: 16 bits = 2 bytes, 8533 MT/s
# 带宽: 2 bytes × 8533 MT/s = 17 GB/s per channel
# 4 通道: 68 GB/s
lpddrx_bus_width_bytes = 2  # 16-bit bus = 2 bytes
lpddrx_mts = 8533  # MT/s per pin
lpddrx_num_ch = 4  # 4ch for single chip (expandable via SerDes)
lpddrx_bw_per_ch = lpddrx_bus_width_bytes * lpddrx_mts / 1000  # GB/s per channel
lpddrx_bw_gbs = lpddrx_num_ch * lpddrx_bw_per_ch
print(f"\nLPDDR5X: {lpddrx_num_ch}ch × {lpddrx_bus_width_bytes}B × {lpddrx_mts}MT/s = {lpddrx_bw_gbs:.1f} GB/s")

# ===== 关键修正：GEMV bytes/MAC = 2B，不是 4B =====
# LLM decode = GEMV = W[N,K] · x[K]
# 权重 W: 全量流式读取 (DRAM 流量主体)
# 激活 x: 一次性读入，被 N 行复用
# 所以 bytes/MAC = 2B (只算权重)
bytes_per_mac = 2  # GEMV: 只读权重，激活复用
print(f"\n关键修正: GEMV bytes/MAC = {bytes_per_mac}B (不是 4B)")
print(f"  原因: 激活向量 x[K] 一次性读入，被 N 行复用")
print(f"  铁证: 7B bf16 = 14GB 权重，每 token 做 7×10⁹ MAC → 14GB ÷ 7B = 2B/MAC")

max_macs = lpddrx_bw_gbs / bytes_per_mac  # 理论最大 MAC 数
max_macs_util = max_macs * 0.85  # 85% 利用率
print(f"\n理论最大 MAC: {max_macs:.0f}")
print(f"85% 利用率下: {max_macs_util:.0f}")

num_macs = 34  # 修正回 34 (2B/MAC 口径，100% 利用率)
print(f"选择: {num_macs} MAC")
print(f"验证: {num_macs} × {bytes_per_mac}B × 1.0GHz = {num_macs * bytes_per_mac * 1:.1f} GB/s = {num_macs * bytes_per_mac * 1 / lpddrx_bw_gbs * 100:.0f}% 利用率")

# ===== 2. 各模块晶体管数 =====
print("\n--- 各模块晶体管数 ---")

# 14nm: 每个 MAC 约 3000-5000 晶体管
t_per_mac = 4000
total_mac = num_macs * t_per_mac
print(f"MAC 阵列: {num_macs} × {t_per_mac:,}T = {total_mac:,}T ({total_mac/1e6:.1f}M)")

# 2MB SRAM = 2097152 bits, 6T-SRAM cell = 6 transistors per bit
sram_bits = 2 * 1024 * 1024 * 8  # 2MB in bits
t_per_bit = 6  # 6T-SRAM cell
total_sram = sram_bits * t_per_bit
print(f"SRAM 2MB: {sram_bits:,} bits × 6T = {total_sram:,}T ({total_sram/1e6:.1f}M)")
print(f"  (旧算法: 2048KB × 20,000T = 41M → 错误，应为 {total_sram/1e6:.1f}M)")

# LPDDR5X PHY: 4ch, 每 ch PHY 约 5M 晶体管 (14nm)
lpddrx_phy = 4 * 5_000_000
print(f"LPDDR5X PHY: 4ch × 5M = {lpddrx_phy:,}T ({lpddrx_phy/1e6:.1f}M)")

# SerDes 互连: 4 lanes × 2 = 8 PHY, 每 lane 2M 晶体管
serdes_lanes = 8
serdes_per_lane = 2_000_000
serdes_phy = serdes_lanes * serdes_per_lane
print(f"SerDes 互连: {serdes_lanes} lanes × 2M = {serdes_phy:,}T ({serdes_phy/1e6:.1f}M)")

# PCIe Gen4 x16: ~15M 晶体管
pcie = 15_000_000
print(f"PCIe Gen4 x16: {pcie:,}T ({pcie/1e6:.1f}M)")

# 控制逻辑 (DMA, 调度器, 命令解析)
control = 12_000_000
print(f"控制逻辑: {control:,}T ({control/1e6:.1f}M)")

# 其他 (时钟、复位、测试)
other = 5_000_000
print(f"其他: {other:,}T ({other/1e6:.1f}M)")

# ===== 3. 总计 =====
total = total_mac + total_sram + lpddrx_phy + serdes_phy + pcie + control + other

print("\n" + "=" * 60)
print(f"总计: {total:,}T = {total/1e6:.1f}M = {total/1e9:.3f}B")
print("=" * 60)

# 对比
print(f"\n--- 对比 ---")
print(f"RTX 3090:     283 亿 (28.3B)")
print(f"我们的芯片:   {total/1e6:.0f}M ({total/1e9:.3f}B)")
print(f"比例: 1/{283e9/total:.0f}")

# ===== 4. 芯片面积 =====
# 14nm FinFET: ~30-40M T/mm² (中芯国际14nm)
# 注意: 55M T/mm² 是 10nm 水平，不是 14nm
density_per_mm2 = 30e6  # 30M T/mm² (中芯国际 14nm)
die_area = total / density_per_mm2

print(f"\n--- 14nm FinFET 芯片面积 ---")
print(f"密度: {density_per_mm2/1e6:.0f}M T/mm² (中芯国际 14nm)")
print(f"面积: {die_area:.1f} mm²")
print(f"RTX 3090: 628 mm² (8nm)")
print(f"比例: 1/{628/die_area:.0f}")

# 各模块面积占比
area_mac = total_mac / density_per_mm2
area_sram = total_sram / density_per_mm2
area_phy = (lpddrx_phy + serdes_phy) / density_per_mm2
area_other = (pcie + control + other) / density_per_mm2

print(f"\n--- 面积占比 ---")
print(f"MAC 阵列: {area_mac:.2f} mm² ({area_mac/die_area*100:.1f}%)")
print(f"SRAM:     {area_sram:.1f} mm² ({area_sram/die_area*100:.1f}%)")
print(f"PHY:      {area_phy:.1f} mm² ({area_phy/die_area*100:.1f}%)")
print(f"其他:     {area_other:.1f} mm² ({area_other/die_area*100:.1f}%)")

# ===== 5. 功耗 =====
# 14nm: 更低电压 (0.7V)，但更高密度
voltage_v = 0.75  # 14nm 典型电压
cap_per_t_ff = 0.8  # 14nm 更小的电容
alpha = 0.20  # 20% 活动因子 (GEMV 比 GEMM 更高)

energy_per_switch = cap_per_t_ff * 1e-15 * voltage_v**2
clock_ghz = 1.0  # 1.0 GHz (14nm)
dynamic_w = total * alpha * energy_per_switch * clock_ghz * 1e9

# 静态功耗 (14nm 漏电更高，但面积小)
static_w = die_area * 0.05  # 50 mW/mm² (14nm FinFET)
total_power = dynamic_w + static_w

print(f"\n--- 功耗 ---")
print(f"时钟频率: {clock_ghz} GHz (14nm)")
print(f"电压: {voltage_v} V")
print(f"动态功耗: {dynamic_w:.1f}W")
print(f"静态功耗: {static_w:.1f}W")
print(f"总功耗: {total_power:.1f}W")

# 效率
macs_per_watt = num_macs / total_power * 1e9  # GMAC/s/W
print(f"能效: {macs_per_watt:.0f} GMAC/s/W")

# ===== 6. 性能 =====
model_size_gb = 14  # 7B bf16
t_per_token = model_size_gb / lpddrx_bw_gbs * 1000
tps = 1000 / t_per_token

print(f"\n--- LLM 推理 (7B bf16) ---")
print(f"每 token: {model_size_gb} GB 数据搬运")
print(f"耗时: {t_per_token:.1f} ms")
print(f"吞吐: {tps:.1f} tok/s")
print(f"RTX 3090 实际: ~30-40 tok/s")

# ===== 7. 成本估算 =====
# MPW: 拼片，只拿到几十~几百颗，不是整片晶圆
# 14nm MPW: ¥100-300万
# 每片晶圆可切: die_area 对应的芯片数
# 但 MPW 只给你 100-200 颗
mpw_cost = 2_000_000  # 200万 MPW
chips_per_wafer = (300**2 * math.pi / 4) / die_area  # 300mm 晶圆
mpw_chips = 150  # MPW 拼片通常给 100-200 颗
cost_per_chip_mpw = mpw_cost / mpw_chips

# 量产: 1000+ 颗
mass_chips = 1000
mass_yield = 0.85
mass_good = chips_per_wafer * mass_yield
cost_per_chip_mass = mpw_cost / mass_good  # 假设 same MPW cost for mass (实际更低)

print(f"\n--- 成本估算 ---")
print(f"MPW 费用: ¥{mpw_cost/1e4:.0f}万")
print(f"每片晶圆: {chips_per_wafer:.0f} 颗")
print(f"MPW 拼片: {mpw_chips} 颗")
print(f"MPW 单颗成本: ¥{cost_per_chip_mpw:,.0f}")
print(f"量产良率: {mass_yield*100:.0f}%")
print(f"量产可用: {mass_good:.0f} 颗")
print(f"量产单颗成本: ¥{cost_per_chip_mass:,.0f}")
print(f"目标售价: ¥{cost_per_chip_mass*3:,.0f}-{cost_per_chip_mass*5:,.0f}")

# ===== 8. 总结 =====
print(f"\n" + "=" * 60)
print(f"最终规格:")
print(f"  工艺: 14nm FinFET (中芯国际)")
print(f"  MAC 数: {num_macs}")
print(f"  SRAM: 2MB ({total_sram/1e6:.1f}M 晶体管)")
print(f"  内存: LPDDR5X 8GB ({lpddrx_num_ch}ch)")
print(f"  带宽: {lpddrx_bw_gbs:.0f} GB/s")
print(f"  面积: {die_area:.1f} mm²")
print(f"  功耗: {total_power:.1f}W")
print(f"  晶体管: {total/1e6:.0f}M ({total/1e9:.3f}B)")
print(f"  接口: PCIe Gen4 x16 + SerDes {serdes_lanes}×")
print(f"  多芯片: 2-14 颗互连")
print(f"  MPW 成本: ¥{cost_per_chip_mpw:,.0f}/颗")
print(f"  量产成本: ¥{cost_per_chip_mass:,.0f}/颗")
print(f"=" * 60)
