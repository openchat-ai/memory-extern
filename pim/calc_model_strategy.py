#!/usr/bin/env python3
"""
模型部署策略计算器
输入模型参数 + 集群配置，输出最佳部署方案
"""
import math

# ===== 芯片规格 =====
MEM_BW = 171  # GB/s/chip
SERDES_BW = 50  # GB/s/chip
MEM_CAPACITY = 128  # GB/chip
CHIP_POWER = 30  # W
CHIP_COST = 1174  # RMB

# ===== 集群配置 =====
SERVERS = 1000
CHIPS_PER_SERVER = 896  # 112 × 8
TOTAL_CHIPS = SERVERS * CHIPS_PER_SERVER
INTRA_BW = SERDES_BW  # 服务器内：SerDes
INTER_BW = 50  # 服务器间：400 GbE (50 GB/s)
# INTER_BW = 12.5  # 服务器间：100 GbE (12.5 GB/s)


def calc_dense(model_name, weight_gb, layers, hidden_dim):
    """Dense 模型性能"""
    total_bw = TOTAL_CHIPS * MEM_BW
    tok_per_s = total_bw / (layers * weight_gb)

    # All-reduce
    msg_bytes = hidden_dim * 2  # bf16
    # 服务器内
    intra_ar = (CHIPS_PER_SERVER - 1) / CHIPS_PER_SERVER * msg_bytes / (INTRA_BW * 1e9) * 1e3  # ms
    # 服务器间
    inter_msg = msg_bytes * SERVERS  # 每台出一份
    inter_ar = inter_msg / (INTER_BW * 1e9) * 1e3  # ms
    ar_per_layer = intra_ar + inter_ar
    ar_total = ar_per_layer * layers

    # 时间
    compute_time = layers * weight_gb / total_bw * 1000  # ms
    total_time = compute_time + ar_total

    return {
        "type": "Dense",
        "model": model_name,
        "weight_gb": weight_gb,
        "layers": layers,
        "total_bw": total_bw,
        "tok_per_s": 1000 / total_time if total_time > 0 else 0,
        "compute_ms": compute_time,
        "ar_ms": ar_total,
        "ar_pct": ar_total / total_time * 100 if total_time > 0 else 0,
        "chips_used": TOTAL_CHIPS,
    }


def calc_moe_split(model_name, total_experts, active_experts, activated_gb, layers, hidden_dim):
    """MoE 模型（expert 拆分到所有芯片）"""
    total_bw = TOTAL_CHIPS * MEM_BW
    tok_per_s_theory = total_bw / (layers * activated_gb)

    # All-reduce
    msg_bytes = hidden_dim * 2
    intra_ar = (CHIPS_PER_SERVER - 1) / CHIPS_PER_SERVER * msg_bytes / (INTRA_BW * 1e9) * 1e3
    inter_msg = msg_bytes * SERVERS
    inter_ar = inter_msg / (INTER_BW * 1e9) * 1e3
    ar_per_layer = intra_ar + inter_ar
    ar_total = ar_per_layer * layers

    compute_time = layers * activated_gb / total_bw * 1000
    total_time = compute_time + ar_total

    return {
        "type": "MoE-split",
        "model": model_name,
        "activated_gb": activated_gb,
        "layers": layers,
        "total_bw": total_bw,
        "tok_per_s": 1000 / total_time if total_time > 0 else 0,
        "tok_per_s_theory": tok_per_s_theory,
        "compute_ms": compute_time,
        "ar_ms": ar_total,
        "ar_pct": ar_total / total_time * 100 if total_time > 0 else 0,
        "chips_used": TOTAL_CHIPS,
        "experts_total": total_experts,
        "experts_active": active_experts,
    }


def calc_moe_nosplit(model_name, total_experts, active_experts, activated_gb, layers, hidden_dim):
    """MoE 模型（expert 不拆分，每 expert 1 颗芯片）"""
    # 每芯片存的 expert 数
    experts_per_chip = total_experts / TOTAL_CHIPS
    active_chips = min(active_experts, TOTAL_CHIPS)
    effective_bw = active_chips * MEM_BW

    # All-reduce（只在 active chips 间）
    msg_bytes = hidden_dim * 2
    # 简化：active chips 在同一台服务器内（理想情况）
    intra_ar = (active_chips - 1) / active_chips * msg_bytes / (INTRA_BW * 1e9) * 1e3
    ar_total = intra_ar * layers

    compute_time = layers * activated_gb / effective_bw * 1000
    total_time = compute_time + ar_total

    return {
        "type": "MoE-nosplit",
        "model": model_name,
        "activated_gb": activated_gb,
        "layers": layers,
        "effective_bw": effective_bw,
        "tok_per_s": 1000 / total_time if total_time > 0 else 0,
        "compute_ms": compute_time,
        "ar_ms": ar_total,
        "ar_pct": ar_total / total_time * 100 if total_time > 0 else 0,
        "chips_used": active_chips,
        "chips_idle": TOTAL_CHIPS - active_chips,
        "experts_per_chip": experts_per_chip,
        "experts_total": total_experts,
        "experts_active": active_experts,
    }


def print_result(r, h200_tps=None, h100_tps=None):
    """打印结果"""
    print(f"\n{'='*60}")
    print(f"  {r['type']}: {r['model']}")
    print(f"{'='*60}")

    if r["type"] == "Dense":
        print(f"  权重/层: {r['weight_gb']:.1f} GB, {r['layers']} 层")
        print(f"  总带宽: {r['total_bw']:,.0f} GB/s ({TOTAL_CHIPS:,} 颗芯片)")
        print(f"  tok/s: {r['tok_per_s']:,.1f}")
        if h100_tps:
            print(f"  vs H100: {r['tok_per_s']/h100_tps:.1f}x")
    else:
        print(f"  激活权重/层: {r['activated_gb']:.1f} GB, {r['layers']} 层")
        if r["type"] == "MoE-split":
            print(f"  Expert: {r['experts_total']} total, {r['experts_active']} active/token")
            print(f"  总带宽: {r['total_bw']:,.0f} GB/s ({TOTAL_CHIPS:,} 颗芯片)")
            print(f"  tok/s: {r['tok_per_s']:,.1f} (理论 {r['tok_per_s_theory']:,.0f})")
        else:
            print(f"  Expert: {r['experts_total']} total, {r['experts_active']} active/token")
            print(f"  每芯片: {r['experts_per_chip']:.1f} expert, 激活 {r['chips_used']:.0f} 颗")
            print(f"  有效带宽: {r['effective_bw']:,.0f} GB/s")
            print(f"  tok/s: {r['tok_per_s']:,.1f}")
            print(f"  空闲芯片: {r['chips_idle']:.0f} ({r['chips_idle']/TOTAL_CHIPS*100:.1f}%)")

        if h200_tps:
            print(f"  vs H200: {r['tok_per_s']/h200_tps:.1f}x")

    print(f"  计算: {r['compute_ms']:.2f} ms/token")
    print(f"  通信: {r['ar_ms']:.2f} ms/token ({r['ar_pct']:.1f}%)")


# ===== 模型定义 =====

# Dense 模型
DENSE_MODELS = [
    ("Llama-7B bf16", 14, 32, 4096),
    ("Llama-70B bf16", 140, 80, 8192),
    ("Llama-70B Q4", 35, 80, 8192),
    ("Llama-405B bf16", 810, 126, 16384),
]

# MoE 模型
MOE_MODELS = [
    ("K3 MoE (896E)", 896, 16, 104, 0.5, 93, 7168),
    ("K3 MoE (896E, no split)", 896, 16, 104, 0.5, 93, 7168),
    ("DeepSeek-V3 (256E)", 256, 8, 37, 0.5, 61, 7168),
    ("Mixtral (8E)", 8, 2, 4.5, 0.5, 32, 4096),
]

# ===== 主程序 =====
print("=" * 70)
print("模型部署策略分析")
print("=" * 70)
print(f"集群: {SERVERS} 台服务器 × {CHIPS_PER_SERVER} 颗 = {TOTAL_CHIPS:,} 颗芯片")
print(f"服务器内: {INTRA_BW} GB/s (SerDes)")
print(f"服务器间: {INTER_BW} GB/s (400GbE)" if INTER_BW == 50 else f"服务器间: {INTER_BW} GB/s (100GbE)")
print(f"芯片总带宽: {TOTAL_CHIPS * MEM_BW:,.0f} GB/s")
print(f"芯片总内存: {TOTAL_CHIPS * MEM_CAPACITY:,.0f} GB")

# H200 基准
H200_BW = 4800
H100_BW = 3350

# Dense 模型
print("\n" + "=" * 70)
print("一、Dense 模型（所有芯片都能工作）")
print("=" * 70)

results_dense = []
for name, weight_gb, layers, hidden in DENSE_MODELS:
    r = calc_dense(name, weight_gb, layers, hidden)
    h100_tps = H100_BW / weight_gb  # 单层时间
    h100_tps = 1 / (layers * weight_gb / H100_BW)
    results_dense.append((r, h100_tps))
    print_result(r, h100_tps=h100_tps)

# MoE 模型
print("\n" + "=" * 70)
print("二、MoE 模型")
print("=" * 70)

results_moe = []
for name, total_e, active_e, total_params, bpp, layers, hidden in MOE_MODELS:
    activated_gb = total_params * bpp
    h200_tps = 1 / (layers * activated_gb / H200_BW)

    if "no split" in name:
        r = calc_moe_nosplit(name, total_e, active_e, activated_gb, layers, hidden)
    else:
        r = calc_moe_split(name, total_e, active_e, activated_gb, layers, hidden)
    results_moe.append((r, h200_tps))
    print_result(r, h200_tps=h200_tps)

# 数据并行（每台独立跑，无跨服务器通信）
print("\n" + "=" * 70)
print("三、数据并行（每台服务器独立推理，无跨服务器通信）")
print("=" * 70)

# 单台服务器性能（896 颗芯片，服务器内 SerDes 互连）
SERVER_CHIPS = 896

print(f"\n单台服务器（{SERVER_CHIPS} 颗芯片，SerDes 互连）:")
print(f"{'模型':<25} {'模式':<15} {'tok/s':<10} {'vs GPU':<10}")
print("-" * 60)

single_server_results = []

for name, weight_gb, layers, hidden in DENSE_MODELS:
    total_bw = SERVER_CHIPS * MEM_BW
    msg_bytes = hidden * 2
    intra_ar = (SERVER_CHIPS - 1) / SERVER_CHIPS * msg_bytes / (INTRA_BW * 1e9) * 1e3
    ar_total = intra_ar * layers
    compute_time = layers * weight_gb / total_bw * 1000
    total_time = compute_time + ar_total
    tps = 1000 / total_time if total_time > 0 else 0
    h100_tps = 1 / (layers * weight_gb / H100_BW)
    single_server_results.append((name, "Dense", tps, h100_tps))
    print(f"{name:<25} {'Dense':<15} {tps:>8.1f}  {tps/h100_tps:>6.1f}x")

for name, total_e, active_e, total_params, bpp, layers, hidden in MOE_MODELS:
    activated_gb = total_params * bpp
    if "no split" in name:
        # 不拆分：只有 active_experts 颗芯片工作
        active_chips = min(active_e, SERVER_CHIPS)
        effective_bw = active_chips * MEM_BW
        msg_bytes = hidden * 2
        intra_ar = (active_chips - 1) / active_chips * msg_bytes / (INTRA_BW * 1e9) * 1e3
        ar_total = intra_ar * layers
        compute_time = layers * activated_gb / effective_bw * 1000
        total_time = compute_time + ar_total
        tps = 1000 / total_time if total_time > 0 else 0
        mode = "MoE-nosplit"
    else:
        # 拆分：所有芯片参与
        total_bw = SERVER_CHIPS * MEM_BW
        msg_bytes = hidden * 2
        intra_ar = (SERVER_CHIPS - 1) / SERVER_CHIPS * msg_bytes / (INTRA_BW * 1e9) * 1e3
        ar_total = intra_ar * layers
        compute_time = layers * activated_gb / total_bw * 1000
        total_time = compute_time + ar_total
        tps = 1000 / total_time if total_time > 0 else 0
        mode = "MoE-split"
    h200_tps = 1 / (layers * activated_gb / H200_BW)
    single_server_results.append((name, mode, tps, h200_tps))
    print(f"{name:<25} {mode:<15} {tps:>8.1f}  {tps/h200_tps:>6.1f}x")

# 集群数据并行
print(f"\n集群数据并行（{SERVERS} 台服务器 × 单台 tok/s，无跨服务器通信）:")
print(f"{'模型':<25} {'模式':<15} {'集群 tok/s':<12} {'vs GPU':<10}")
print("-" * 62)

for name, mode, tps, h_tps in single_server_results:
    cluster_tps = tps * SERVERS
    print(f"{name:<25} {mode:<15} {cluster_tps:>10,.0f}  {cluster_tps/h_tps:>6.0f}x")

# 最佳模式对比
print("\n" + "=" * 70)
print("四、各模型最佳部署模式")
print("=" * 70)

print(f"\n{'模型':<25} {'最佳模式':<15} {'tok/s':<12} {'vs GPU':<10} {'通信占比':<10}")
print("-" * 72)

for r, h in results_dense:
    print(f"{r['model']:<25} {'Dense-张量':<15} {r['tok_per_s']:>10,.1f}  {r['tok_per_s']/h:>6.1f}x   {r['ar_pct']:>5.1f}%")

for r, h in results_moe:
    mode = "MoE-split-张量" if r["type"] == "MoE-split" else "MoE-nosplit"
    print(f"{r['model']:<25} {mode:<15} {r['tok_per_s']:>10,.1f}  {r['tok_per_s']/h:>6.1f}x   {r['ar_pct']:>5.1f}%")

print(f"\n{'模型':<25} {'数据并行':<15} {'集群 tok/s':<12} {'vs GPU':<10} {'通信占比':<10}")
print("-" * 72)

for name, mode, tps, h_tps in single_server_results:
    cluster_tps = tps * SERVERS
    print(f"{name:<25} {'数据并行':<15} {cluster_tps:>10,.0f}  {cluster_tps/h_tps:>6.0f}x   {'0.0%':>8}")

# 关键发现
print("\n" + "=" * 70)
print("五、关键发现")
print("=" * 70)

print("\n张量并行 vs 数据并行:")
print("  张量并行：所有芯片一起算一个 token → 通信是瓶颈（99%+）")
print("  数据并行：每台独立算不同 token → 无跨服务器通信")
print("  结论：大规模集群必须用数据并行")

# 通信瓶颈分析
print("\n通信瓶颈分析（张量并行）:")
for r, h in results_dense + results_moe:
    if r["ar_pct"] > 10:
        print(f"  ⚠️ {r['model']}: 通信占 {r['ar_pct']:.1f}%，是瓶颈")
    elif r["ar_pct"] > 1:
        print(f"  ⚠️ {r['model']}: 通信占 {r['ar_pct']:.1f}%，有压力")
    else:
        print(f"  ✅ {r['model']}: 通信占 {r['ar_pct']:.1f}%，可忽略")

# 性价比
print("\n性价比分析（数据并行，集群）:")
total_cost = TOTAL_CHIPS * CHIP_COST
total_power = TOTAL_CHIPS * CHIP_POWER
print(f"  总成本: ¥{total_cost:,.0f}")
print(f"  总功耗: {total_power:,.0f}W")
for name, mode, tps, h_tps in single_server_results:
    cluster_tps = tps * SERVERS
    if "Dense" in name or "bf16" in name:
        gpu_equiv = cluster_tps / h_tps * 78000
    else:
        gpu_equiv = cluster_tps / h_tps * 350000
    price_ratio = gpu_equiv / total_cost if total_cost > 0 else 0
    print(f"  {name}: 等效 GPU 成本 ¥{gpu_equiv:,.0f}, 性价比 {price_ratio:.1f}x")
