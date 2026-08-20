#!/usr/bin/env python3
"""估算 GEMV-only 芯片的晶体管数量"""
import math

print("=" * 60)
print("GEMV 芯片晶体管估算")
print("=" * 60)

# ===== 参数 =====
gddr6x_bandwidth_gbs = 384 * 21 / 8  # GB/s
print(f"\n内存带宽（GDDR6X 384-bit）: {gddr6x_bandwidth_gbs:.0f} GB/s")

model_size_gb = 14  # 7B bf16
clock_ghz = 1.0

# ===== 计算需求 =====
bytes_per_mac = 2 * 2  # 2 bf16 = 4 bytes
macs_per_second = gddr6x_bandwidth_gbs * 1e9 / bytes_per_mac
print(f"内存带宽可支撑的 MAC 速率: {macs_per_second/1e9:.0f} GMAC/s")

macs_per_unit_per_second = clock_ghz * 1e9
num_mac_units = math.ceil(macs_per_second / macs_per_unit_per_second)
print(f"饱和内存带宽需要的 MAC 单元数: {num_mac_units}")

# ===== 晶体管估算 =====
print("\n--- 各模块晶体管数 ---")

transistors_per_mac = 4000
total_mac = num_mac_units * transistors_per_mac
print(f"MAC 阵列: {num_mac_units} x {transistors_per_mac}T = {total_mac:,}T ({total_mac/1e6:.1f}M)")

sram_bytes = 2 * 1024 * 1024
total_sram = sram_bytes * 8 * 20
print(f"SRAM 2MB: {total_sram:,}T ({total_sram/1e6:.1f}M)")

total_gddr6x = 4 * 5_000_000
print(f"GDDR6X 控制器: {total_gddr6x:,}T ({total_gddr6x/1e6:.1f}M)")

pcie = 15_000_000
print(f"PCIe Gen4 x16: {pcie:,}T ({pcie/1e6:.1f}M)")

control = 10_000_000
print(f"控制逻辑: {control:,}T ({control/1e6:.1f}M)")

other = 5_000_000
print(f"其他: {other:,}T ({other/1e6:.1f}M)")

total = total_mac + total_sram + total_gddr6x + pcie + control + other

print("\n" + "=" * 60)
print(f"总计: {total:,}T = {total/1e6:.1f}M = {total/1e9:.2f}B")
print("=" * 60)

print(f"\n--- 对比 ---")
print(f"RTX 3090:  28.3B (283 亿)")
print(f"我们的芯片: {total/1e9:.2f}B ({total/1e6:.0f}M)")
print(f"比例: 1/{283e9/total:.0f}")

# ===== 芯片面积 =====
die_area = total / 8e6
print(f"\n--- 28nm 芯片面积 ---")
print(f"密度: 8M T/mm2")
print(f"面积: {die_area:.1f} mm2")
print(f"RTX 3090: 628 mm2 (8nm)")
print(f"比例: 1/{628/die_area:.0f}")

# ===== 功耗 =====
# P = C * V^2 * f * N * alpha
# 28nm: C ~1fF/transistor, V ~0.9V, f = 1GHz, alpha = activity factor
cap_per_transistor_ff = 1.0  # fF
voltage_v = 0.9
alpha = 0.15  # 15% overall activity (SRAM mostly idle)
energy_per_switch = cap_per_transistor_ff * 1e-15 * voltage_v**2  # Joules
dynamic_w = total * alpha * energy_per_switch * clock_ghz * 1e9
print(f"\n--- 功耗 ---")
print(f"动态: {dynamic_w:.1f}W")
print(f"含静态 (~30%): {dynamic_w*1.3:.1f}W")

# ===== 性能 =====
t_per_token = model_size_gb / gddr6x_bandwidth_gbs * 1000
tps = 1000 / t_per_token
print(f"\n--- LLM 推理 (7B bf16) ---")
print(f"每 token: {model_size_gb} GB 数据搬运")
print(f"耗时: {t_per_token:.1f} ms")
print(f"吞吐: {tps:.1f} tok/s")
print(f"RTX 3090 实际: ~30-40 tok/s")
