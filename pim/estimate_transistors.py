#!/usr/bin/env python3
"""估算 LLM 推理 GEMV 芯片的晶体管/功耗/性能（GDDR7 / LPDDR5X 双模式）"""
import math

print("=" * 60)
print("LLM 推理 GEMV 芯片估算")
print("=" * 60)

# ===== 参数 =====
MODELS = {
    "GDDR7 (12x128GB/s)": {"bw_gb": 12 * 128, "bw": 1.5e12, "mem_w": 40, "cost": 400},
    "LPDDR5X (12x38GB/s)": {"bw_gb": 12 * 38, "bw": 460e9, "mem_w": 15, "cost": 350},
}
MODEL_GB = 15.36  # Qwen3.6-35B-A3B Q3_K_S gguf
CLOCK_GHZ = 1.0

for label, m in MODELS.items():
    print(f"\n{'=' * 60}")
    print(f"模式: {label}  ({m['bw_gb']:.0f} GB/s)")
    print(f"{'=' * 60}")
    bw = m["bw_gb"]

    bytes_per_mac = 2 * 2
    macs_per_second = bw * 1e9 / bytes_per_mac
    print(f"  内存带宽可支撑 MAC 速率: {macs_per_second/1e9:.0f} GMAC/s")

    num_mac = math.ceil(macs_per_second / (CLOCK_GHZ * 1e9))
    print(f"  饱和带宽需要的 MAC 单元数: {num_mac}")

    # ===== 晶体管 =====
    T_MAC = num_mac * 4000
    T_SRAM = 2 * 1024 * 1024 * 8 * 20  # 2MB
    T_MEM = 4 * 5_000_000
    T_PCIE = 15_000_000
    T_CTRL = 10_000_000
    T_OTHER = 5_000_000
    T_TOTAL = T_MAC + T_SRAM + T_MEM + T_PCIE + T_CTRL + T_OTHER

    print(f"\n--- 晶体管 ---")
    print(f"  MAC 阵列 ({num_mac}x4k):  {T_MAC:>10,}T ({T_MAC/1e6:.1f}M)")
    print(f"  SRAM 2MB:                {T_SRAM:>10,}T ({T_SRAM/1e6:.1f}M)")
    print(f"  内存控制器:              {T_MEM:>10,}T ({T_MEM/1e6:.1f}M)")
    print(f"  PCIe Gen4 x16:           {T_PCIE:>10,}T ({T_PCIE/1e6:.1f}M)")
    print(f"  控制逻辑:                {T_CTRL:>10,}T ({T_CTRL/1e6:.1f}M)")
    print(f"  其他:                    {T_OTHER:>10,}T ({T_OTHER/1e6:.1f}M)")
    print(f"  {'─'*40}")
    print(f"  总计:                    {T_TOTAL:>10,}T ({T_TOTAL/1e6:.1f}M = {T_TOTAL/1e9:.2f}B)")

    # ===== 面积 =====
    DIE_DENSITY = 8e6  # 28nm
    area = T_TOTAL / DIE_DENSITY
    print(f"\n--- 28nm 面积 ({DIE_DENSITY/1e6:.0f}M T/mm²) ---")
    print(f"  {area:.1f} mm²  (RTX 3090: 628 mm² @ 8nm, 比例 1/{628/area:.0f})")

    # ===== 功耗 =====
    cap_ff, volt, alpha = 1.0, 0.9, 0.15
    dW = T_TOTAL * alpha * (cap_ff * 1e-15 * volt**2) * CLOCK_GHZ * 1e9
    print(f"\n--- 功耗 ---")
    print(f"  动态: {dW:.1f}W")
    print(f"  含静态 30%: {dW*1.3:.1f}W")
    print(f"  内存颗粒: {m['mem_w']}W")
    print(f"  总计: {dW*1.3 + m['mem_w']:.0f}W")

    # ===== 性能 =====
    tms = MODEL_GB / bw * 1000
    tps = 1000 / tms
    print(f"\n--- LLM 推理 ({MODEL_GB}GB Q3_K_S) ---")
    print(f"  每 token: {tms:.2f} ms")
    print(f"  吞吐: {tps:.1f} tok/s")
    print(f"  芯片成本: ${m['cost']}")
