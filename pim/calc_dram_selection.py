#!/usr/bin/env python3
"""
DRAM 选型分析
对比不同 DRAM 方案的性能、成本、功耗
"""
import math

# ===== DRAM 方案 =====
# 每通道带宽 = MT/s × bus_width / 8
# LPDDR5X: 10667 MT/s × 16bit = 21.3 GB/s/ch
# LPDDR5: 6400 MT/s × 16bit = 12.8 GB/s/ch
# DDR5: 4800 MT/s × 8bit = 4.8 GB/s/ch (DIMM)
# HBM2e: 3.2 GT/s × 1024bit = 410 GB/s/stack
# HBM3: 6.4 GT/s × 1024bit = 819 GB/s/stack

DRAM_OPTIONS = {
    "LPDDR5X-8ch": {
        "channels": 8,
        "mt_s": 10667,
        "bus_width_bits": 16,
        "die_size_gb": 16,
        "price_per_gb": 35,  # RMB
        "power_per_chip": 5,  # W (DRAM only)
        "available": True,
        "note": "长鑫/Samsung/SK Hynix, 手机级供应链",
    },
    "LPDDR5X-4ch": {
        "channels": 4,
        "mt_s": 10667,
        "bus_width_bits": 16,
        "die_size_gb": 16,
        "price_per_gb": 35,
        "power_per_chip": 3,
        "available": True,
        "note": "省一半 DRAM，带宽减半",
    },
    "LPDDR5-8ch": {
        "channels": 8,
        "mt_s": 6400,
        "bus_width_bits": 16,
        "die_size_gb": 16,
        "price_per_gb": 28,
        "power_per_chip": 4,
        "available": True,
        "note": "便宜 20%，慢 40%",
    },
    "DDR5-8ch": {
        "channels": 8,
        "mt_s": 4800,
        "bus_width_bits": 8,  # DIMM 是 8-bit
        "die_size_gb": 32,
        "price_per_gb": 20,
        "power_per_chip": 6,
        "available": True,
        "note": "服务器标准，便宜但慢",
    },
    "HBM2e-4stack": {
        "channels": 4,
        "mt_s": 3200,
        "bus_width_bits": 1024,  # 每 stack 1024-bit
        "die_size_gb": 8,
        "price_per_gb": 150,
        "power_per_chip": 8,
        "available": False,  # 买不到
        "note": "SK Hynix/Samsung, 不卖给小公司",
    },
    "HBM3-4stack": {
        "channels": 4,
        "mt_s": 6400,
        "bus_width_bits": 1024,
        "die_size_gb": 12,
        "price_per_gb": 200,
        "power_per_chip": 12,
        "available": False,
        "note": "最新一代，更贵更难买",
    },
}

# ===== 芯片配置 =====
MAC_COUNT = 68
CLOCK_GHZ = 1.0
BYTES_PER_MAC = 4  # bf16: 2B 权重(DRAM) + 2B 激活(SRAM) = 4B
COMPUTE_BW = MAC_COUNT * CLOCK_GHZ * BYTES_PER_MAC  # 272 GB/s
WEIGHT_BW = MAC_COUNT * CLOCK_GHZ * 2  # 136 GB/s (仅权重，从 DRAM 读)

SERDES_LANES = 4
SERDES_RATE_GBPS = 100
SERDES_BW = SERDES_LANES * SERDES_RATE_GBPS / 8  # 50 GB/s

CHIP_POWER_BASE = 20  # W (不含 DRAM)
CHIP_COST_BASE = 500  # RMB (不含 DRAM, 封装等)

# ===== 模型 =====
MODELS = [
    ("Llama-7B bf16", "dense", 14, 32, 4096),
    ("Llama-70B bf16", "dense", 140, 80, 8196),
    ("K3 MoE (896E, split)", "moe", 52, 93, 7168, 896, 16),
]


def calc_dram_spec(dram_name, dram_config):
    """计算 DRAM 规格"""
    ch = dram_config["channels"]
    mt = dram_config["mt_s"]
    bus = dram_config["bus_width_bits"]
    die = dram_config["die_size_gb"]

    bw_per_ch = mt * bus / 8 / 1e3  # GB/s
    total_bw = bw_per_ch * ch
    capacity = ch * die
    price = capacity * dram_config["price_per_gb"]
    power = dram_config["power_per_chip"]

    return {
        "name": dram_name,
        "channels": ch,
        "bw_per_ch": bw_per_ch,
        "total_bw": total_bw,
        "capacity": capacity,
        "price": price,
        "power": power,
        "available": dram_config["available"],
        "note": dram_config["note"],
    }


def calc_perf(dram_spec, model_type, weight_gb, layers, hidden_dim,
               n_chips=1, total_experts=0, active_experts=0):
    """计算性能"""
    total_bw = n_chips * dram_spec["total_bw"]

    # 计算时间
    compute_time = layers * weight_gb / total_bw * 1000  # ms

    # All-reduce
    msg_bytes = hidden_dim * 2
    if n_chips > 1:
        ar_time = (n_chips - 1) / n_chips * msg_bytes / (SERDES_BW * 1e9) * 1e3
    else:
        ar_time = 0
    ar_total = ar_time * layers

    total_time = compute_time + ar_total
    tok_per_s = 1000 / total_time if total_time > 0 else 0

    # 单芯片成本
    chip_cost = CHIP_COST_BASE + dram_spec["price"]
    chip_power = CHIP_POWER_BASE + dram_spec["power"]

    return {
        "tok_per_s": tok_per_s,
        "compute_ms": compute_time,
        "ar_ms": ar_total,
        "ar_pct": ar_total / total_time * 100 if total_time > 0 else 0,
        "chip_cost": chip_cost,
        "chip_power": chip_power,
        "tok_per_w": tok_per_s / chip_power if chip_power > 0 else 0,
        "tok_per_rmb": tok_per_s / chip_cost if chip_cost > 0 else 0,
    }


# ===== 主程序 =====
print("=" * 90)
print("DRAM 选型分析")
print("=" * 90)
print(f"计算带宽: {COMPUTE_BW} GB/s (68 MAC × 1.0 GHz × 4B)")
print(f"权重需求: {WEIGHT_BW} GB/s (仅 DRAM)")
print(f"SerDes: {SERDES_BW} GB/s/chip")
print(f"基础功耗: {CHIP_POWER_BASE}W, 基础成本: ¥{CHIP_COST_BASE}")
print()

# DRAM 规格对比
print("=" * 90)
print("一、DRAM 规格对比")
print("=" * 90)

dram_specs = {}
for name, config in DRAM_OPTIONS.items():
    spec = calc_dram_spec(name, config)
    dram_specs[name] = spec

print(f"\n{'方案':<18} {'通道':>4} {'带宽GB/s':>10} {'容量GB':>8} {'DRAM价格':>10} {'DRAM功耗':>8} {'可买':>4} {'备注'}")
print("-" * 100)

for name, spec in dram_specs.items():
    avail = "✅" if spec["available"] else "❌"
    print(f"{spec['name']:<18} {spec['channels']:>4} {spec['total_bw']:>9.1f} {spec['capacity']:>7.0f} ¥{spec['price']:>8,} {spec['power']:>6.0f}W {avail:>4} {spec['note']}")

# 平衡点分析
print("\n" + "=" * 90)
print("二、计算/内存平衡点")
print("=" * 90)

print(f"\n{'方案':<18} {'带宽GB/s':>10} {'权重需求':>10} {'比值':>6} {'瓶颈':>10} {'可降频':>6}")
print("-" * 70)

for name, spec in dram_specs.items():
    ratio = spec["total_bw"] / WEIGHT_BW
    if ratio < 0.8:
        bottleneck = "DRAM瓶颈"
        can_dvfs = "✅"
    elif ratio > 1.2:
        bottleneck = "计算瓶颈"
        can_dvfs = "❌"
    else:
        bottleneck = "平衡"
        can_dvfs = "❌"
    print(f"{spec['name']:<18} {spec['total_bw']:>9.1f} {WEIGHT_BW:>9.0f} {ratio:>5.2f} {bottleneck:>10} {can_dvfs:>6}")

# 不同 DRAM 下的性能
print("\n" + "=" * 90)
print("三、不同 DRAM 下的单芯片性能")
print("=" * 90)

for model_name, model_type, weight_gb, layers, hidden_dim, *moe_args in MODELS:
    total_e, active_e = moe_args if moe_args else (0, 0)

    print(f"\n--- {model_name} ---")
    print(f"{'方案':<18} {'tok/s':>8} {'成本¥':>8} {'功耗W':>6} {'tok/W':>7} {'tok/¥':>9} {'vs LPDDR5X':>12}")
    print("-" * 70)

    base_tps = None
    for name, spec in dram_specs.items():
        r = calc_perf(spec, model_type, weight_gb, layers, hidden_dim,
                       n_chips=1, total_experts=total_e, active_experts=active_e)
        if base_tps is None:
            base_tps = r["tok_per_s"]
        vs_base = r["tok_per_s"] / base_tps if base_tps > 0 else 0
        print(f"{spec['name']:<18} {r['tok_per_s']:>7.2f} {r['chip_cost']:>7,} {r['chip_power']:>5.0f} {r['tok_per_w']:>6.3f} {r['tok_per_rmb']:>8.5f} {vs_base:>10.2f}x")

# 不同 DRAM 下的多芯片性能（28 颗）
print("\n" + "=" * 90)
print("四、28 颗芯片性能对比")
print("=" * 90)

N_CHIPS = 28

for model_name, model_type, weight_gb, layers, hidden_dim, *moe_args in MODELS:
    total_e, active_e = moe_args if moe_args else (0, 0)

    print(f"\n--- {model_name} ({N_CHIPS} 颗) ---")
    print(f"{'方案':<18} {'总带宽':>10} {'tok/s':>8} {'成本¥':>10} {'功耗W':>7} {'tok/W':>7} {'tok/¥':>9} {'vs LPDDR5X':>12}")
    print("-" * 85)

    base_tps = None
    for name, spec in dram_specs.items():
        r = calc_perf(spec, model_type, weight_gb, layers, hidden_dim,
                       n_chips=N_CHIPS, total_experts=total_e, active_experts=active_e)
        total_bw = N_CHIPS * spec["total_bw"]
        total_cost = N_CHIPS * r["chip_cost"]
        total_power = N_CHIPS * r["chip_power"]

        if base_tps is None:
            base_tps = r["tok_per_s"]
        vs_base = r["tok_per_s"] / base_tps if base_tps > 0 else 0

        print(f"{spec['name']:<18} {total_bw:>8.0f}GB/s {r['tok_per_s']:>7.1f} {total_cost:>9,} {total_power:>6.0f} {r['tok_per_w']:>6.3f} {r['tok_per_rmb']:>8.5f} {vs_base:>10.2f}x")

# 能装下的最大模型
print("\n" + "=" * 90)
print("五、各 DRAM 方案能装下的最大模型")
print("=" * 90)

print(f"\n{'方案':<18} {'容量GB':>8} {'Llama-7B':>10} {'Llama-70B':>10} {'K3 MoE':>10}")
print("-" * 60)

for name, spec in dram_specs.items():
    cap = spec["capacity"]
    llama7 = "✅" if cap >= 14 else "❌"
    llama70 = "✅" if cap >= 140 else "❌"
    k3 = "✅" if cap >= 52 else "❌"  # 激活权重
    print(f"{spec['name']:<18} {cap:>7.0f} {llama7:>10} {llama70:>10} {k3:>10}")

# 总结
print("\n" + "=" * 90)
print("六、总结")
print("=" * 90)
print(f"""
核心参数:
  68 MAC × 1.0 GHz × 4B = {COMPUTE_BW} GB/s 计算
  68 MAC × 1.0 GHz × 2B = {WEIGHT_BW} GB/s 权重需求 (DRAM)

瓶颈分析:
  DRAM < {WEIGHT_BW} GB/s → DRAM 瓶颈 → MAC 可降频省电
  DRAM > {WEIGHT_BW} GB/s → 计算瓶颈 → MAC 满载

选型建议：
1. LPDDR5X-8ch: 计算瓶颈，MAC 满载，最佳性能
2. LPDDR5X-4ch: DRAM 瓶颈，MAC 可降到 0.63GHz，省电
3. LPDDR5-8ch: 便宜 20%，但慢 40%，不推荐
4. DDR5-8ch: 服务器标准，但 bus width 只有 8-bit，带宽低
5. HBM2e/3: 带宽极高，但买不到且太贵

结论：
- LPDDR5X-8ch 是最佳选择（计算瓶颈，性能最高）
- LPDDR5X-4ch 是低成本选择（DRAM 瓶颈，可省电）
- HBM 只有等量产规模够大才可能买到
- DDR5 带宽不够，不适合 GEMV
""")
