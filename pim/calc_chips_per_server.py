#!/usr/bin/env python3
"""
芯片数 vs 性能分析
每台服务器放多少芯片最优？
"""
import math

# ===== 芯片规格 =====
MEM_BW_PER_CHIP = 171  # GB/s
SERDES_BW = 50  # GB/s/chip
MEM_CAPACITY_PER_CHIP = 128  # GB
CHIP_POWER = 30  # W
CHIP_COST = 1174  # RMB
CHIP_AREA_MM2 = 256  # mm²

# ===== 模型 =====
MODELS = [
    ("Llama-7B bf16", "dense", 14, 32, 4096),
    ("Llama-70B bf16", "dense", 140, 80, 8192),
    ("K3 MoE (896E, split)", "moe", 52, 93, 7168, 896, 16),
    ("DeepSeek-V3 (256E, split)", "moe", 18.5, 61, 7168, 256, 8),
]


def calc_server_perf(n_chips, model_type, weight_gb, layers, hidden_dim,
                      total_experts=0, active_experts=0):
    """单台服务器性能"""
    total_bw = n_chips * MEM_BW_PER_CHIP
    total_mem = n_chips * MEM_CAPACITY_PER_CHIP

    # 计算时间
    compute_time = layers * weight_gb / total_bw * 1000  # ms

    # All-reduce（服务器内 SerDes）
    msg_bytes = hidden_dim * 2  # bf16
    if n_chips > 1:
        # Ring all-reduce: (p-1)/p × msg / bw
        ar_time = (n_chips - 1) / n_chips * msg_bytes / (SERDES_BW * 1e9) * 1e3  # ms
    else:
        ar_time = 0

    ar_total = ar_time * layers
    total_time = compute_time + ar_total
    tok_per_s = 1000 / total_time if total_time > 0 else 0

    # 功耗和成本
    power = n_chips * CHIP_POWER
    cost = n_chips * CHIP_COST
    area = n_chips * CHIP_AREA_MM2

    # PCB 面积估算（假设 2D 排列）
    board_side = math.sqrt(area) * 1.3  # 30% 走线开销
    board_area = board_side ** 2

    return {
        "n_chips": n_chips,
        "total_bw": total_bw,
        "total_mem": total_mem,
        "tok_per_s": tok_per_s,
        "compute_ms": compute_time,
        "ar_ms": ar_total,
        "ar_pct": ar_total / total_time * 100 if total_time > 0 else 0,
        "power": power,
        "cost": cost,
        "area_mm2": area,
        "board_area_mm2": board_area,
        "tok_per_w": tok_per_s / power if power > 0 else 0,
        "tok_per_rmb": tok_per_s / cost if cost > 0 else 0,
    }


# ===== 主程序 =====
print("=" * 80)
print("芯片数 vs 性能分析")
print("=" * 80)
print(f"芯片规格: {MEM_BW_PER_CHIP} GB/s, {MEM_CAPACITY_PER_CHIP} GB, {CHIP_POWER}W, ¥{CHIP_COST}")
print(f"SerDes: {SERDES_BW} GB/s/chip")
print()

for model_name, model_type, weight_gb, layers, hidden_dim, *moe_args in MODELS:
    total_e, active_e = moe_args if moe_args else (0, 0)

    print("=" * 80)
    print(f"模型: {model_name}")
    print("=" * 80)

    # 不同芯片数
    chip_counts = [1, 4, 8, 16, 32, 64, 128, 256, 512, 896, 1024, 2048]

    print(f"{'芯片数':>6} {'总带宽':>10} {'总内存':>8} {'tok/s':>10} {'计算ms':>8} {'通信ms':>8} {'通信%':>7} {'功耗W':>7} {'成本¥':>10} {'tok/W':>7} {'tok/¥':>9}")
    print("-" * 110)

    results = []
    for n in chip_counts:
        if model_type == "dense":
            r = calc_server_perf(n, model_type, weight_gb, layers, hidden_dim)
        else:
            # MoE split: 所有芯片参与
            r = calc_server_perf(n, model_type, weight_gb, layers, hidden_dim,
                                 total_e, active_e)
        results.append(r)
        print(f"{n:>6} {r['total_bw']:>8.0f}GB/s {r['total_mem']:>6.0f}GB {r['tok_per_s']:>9.1f} {r['compute_ms']:>7.3f} {r['ar_ms']:>7.3f} {r['ar_pct']:>6.1f}% {r['power']:>6.0f} {r['cost']:>9,} {r['tok_per_w']:>6.2f} {r['tok_per_rmb']:>8.4f}")

    # 找最优
    print()

    # 最优 tok/s
    best_tps = max(results, key=lambda x: x["tok_per_s"])
    print(f"  最高 tok/s: {best_tps['n_chips']} 颗 → {best_tps['tok_per_s']:.1f} tok/s (通信 {best_tps['ar_pct']:.1f}%)")

    # 最优 tok/W（能效）
    best_epw = max(results, key=lambda x: x["tok_per_w"])
    print(f"  最高能效: {best_epw['n_chips']} 颗 → {best_epw['tok_per_w']:.3f} tok/W")

    # 最优 tok/¥（性价比）
    best_epr = max(results, key=lambda x: x["tok_per_rmb"])
    print(f"  最高性价比: {best_epr['n_chips']} 颗 → {best_epr['tok_per_rmb']:.5f} tok/¥")

    # 通信 < 5% 的最小芯片数
    low_ar = [r for r in results if r["ar_pct"] < 5]
    if low_ar:
        min_low_ar = min(low_ar, key=lambda x: x["n_chips"])
        print(f"  通信 < 5% 的最小配置: {min_low_ar['n_chips']} 颗 ({min_low_ar['tok_per_s']:.1f} tok/s)")

    # tok/s 增长曲线（相邻芯片数的提升倍数）
    print(f"\n  边际收益（每翻倍的 tok/s 提升）:")
    for i in range(1, len(results)):
        r_prev = results[i-1]
        r_curr = results[i]
        if r_prev["tok_per_s"] > 0:
            speedup = r_curr["tok_per_s"] / r_prev["tok_per_s"]
            chip_ratio = r_curr["n_chips"] / r_prev["n_chips"]
            efficiency = speedup / chip_ratio * 100
            print(f"    {r_prev['n_chips']:>5} → {r_curr['n_chips']:>5}: {speedup:.2f}x tok/s (效率 {efficiency:.0f}%)")

    print()

# 热密度分析
print("\n" + "=" * 80)
print("散热分析")
print("=" * 80)

print(f"\n{'芯片数':>6} {'功耗W':>7} {'面积mm²':>10} {'功耗密度W/mm²':>15} {'散热方式':>10}")
print("-" * 55)

for n in [28, 56, 112, 224, 448, 896]:
    power = n * CHIP_POWER
    area = n * CHIP_AREA_MM2
    density = power / area
    if density < 0.1:
        cooling = "风冷"
    elif density < 0.3:
        cooling = "风冷/液冷"
    elif density < 0.5:
        cooling = "液冷"
    else:
        cooling = "必须液冷"
    print(f"{n:>6} {power:>6.0f}W {area:>9,} {density:>13.3f} {cooling:>10}")

# 总结
print("\n" + "=" * 80)
print("总结")
print("=" * 80)
print("""
关键发现：
1. tok/s 随芯片数线性增长（通信可忽略时）
2. 通信占比随芯片数增加而增大（ring all-reduce）
3. 能效（tok/W）不随芯片数变化（线性扩展）
4. 性价比（tok/¥）不随芯片数变化（线性扩展）
5. 散热是物理限制：>224 颗需要液冷

最优芯片数取决于：
- 模型大小（大模型需要更多芯片装权重）
- 通信容忍度（通信 < 5% 为佳）
- 散热限制（液冷成本）
- 物理空间（PCB 面积）
""")
