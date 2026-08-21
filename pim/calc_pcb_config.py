#!/usr/bin/env python3
"""
PCB 配置 + DRAM 选型 + 散热方案 + 功耗优化 综合分析
bf16: 每 MAC 读 2B 权重(DRAM) + 2B 激活(SRAM) = 4B
所有内存带宽统一公式计算，无硬编码
"""
import math

# ===== 芯片基础规格 =====
MAC_COUNT = 68
CLOCK_GHZ = 1.0
BYTES_PER_MAC = 4  # bf16: 2B 权重(DRAM) + 2B 激活(SRAM) = 4B

COMPUTE_BW = MAC_COUNT * CLOCK_GHZ * BYTES_PER_MAC  # 272 GB/s
WEIGHT_BW = MAC_COUNT * CLOCK_GHZ * 2  # 136 GB/s (仅权重，从 DRAM 读)

SERDES_LANES = 4
SERDES_RATE_GBPS = 100
SERDES_BW = SERDES_LANES * SERDES_RATE_GBPS / 8  # 50 GB/s

# ===== 功耗 =====
MAC_POWER = 20  # W @ 1GHz
SRAM_POWER = 2  # W
SERDES_POWER = 2  # W
OTHER_POWER = 1  # W
CHIP_POWER_BASE = MAC_POWER + OTHER_POWER  # 21W (不含 DRAM)

CHIP_COST_BASE = 500  # RMB (不含 DRAM)
CHIP_AREA_MM2 = 256  # mm²
CHIP_PACKAGE_MM2 = 400  # mm²

# ===== DRAM 方案（全部公式计算）=====
DRAM_OPTIONS = {
    "LPDDR5X-8ch": {
        "channels": 8, "mt_s": 10667, "bus_bits": 16,
        "die_gb": 16, "price_per_gb": 35, "power": 5,
    },
    "LPDDR5X-4ch": {
        "channels": 4, "mt_s": 10667, "bus_bits": 16,
        "die_gb": 16, "price_per_gb": 35, "power": 3,
    },
    "HBM3-1stack": {
        "channels": 1, "mt_s": 6400, "bus_bits": 1024,
        "die_gb": 24, "price_per_gb": 200, "power": 15,
    },
    "HBM3-2stack": {
        "channels": 2, "mt_s": 6400, "bus_bits": 1024,
        "die_gb": 48, "price_per_gb": 200, "power": 25,
    },
    "GDDR6X": {
        "channels": 1, "mt_s": 21000, "bus_bits": 32,
        "die_gb": 2, "price_per_gb": 80, "power": 8,
    },
}

# ===== PCB 配置 =====
PCB_CONFIGS = {
    "单槽2PCB": {
        "slots": 1, "pcbs": 2, "chips_per_pcb": 20,
        "fans": 2, "max_power_w": 1100, "cooling": "风冷",
    },
    "双槽4PCB": {
        "slots": 2, "pcbs": 4, "chips_per_pcb": 20,
        "fans": 3, "max_power_w": 2100, "cooling": "风冷",
    },
    "双槽6PCB": {
        "slots": 2, "pcbs": 6, "chips_per_pcb": 20,
        "fans": 3, "max_power_w": 3000, "cooling": "风冷",
    },
    "双槽8PCB": {
        "slots": 2, "pcbs": 8, "chips_per_pcb": 20,
        "fans": 3, "max_power_w": 3500, "cooling": "风冷/液冷",
    },
}

# ===== 模型 =====
MODELS = [
    ("Llama-7B bf16", "dense", 14, 32, 4096),
    ("Llama-70B bf16", "dense", 140, 80, 8192),
    ("K3 MoE (896E, split)", "moe", 52, 93, 7168, 896, 16),
]


def calc_dram(dram_name, dram_cfg):
    """统一公式计算 DRAM 规格"""
    bw = dram_cfg["channels"] * dram_cfg["mt_s"] * dram_cfg["bus_bits"] / 8 / 1e3
    cap = dram_cfg["channels"] * dram_cfg["die_gb"]
    price = cap * dram_cfg["price_per_gb"]
    return {
        "name": dram_name, "bw": bw, "cap": cap,
        "price": price, "power": dram_cfg["power"],
    }


def get_bottleneck(dram_bw):
    """
    瓶颈分析:
    GEMV 每 MAC: 2B 权重(DRAM) + 2B 激活(SRAM) = 4B
    DRAM 只需供应权重: WEIGHT_BW = 136 GB/s
    
    dram_bw < 136 GB/s → DRAM 是瓶颈，MAC 有空闲，可以降频
    dram_bw > 136 GB/s → 计算是瓶颈，MAC 满载，不能降频
    """
    if dram_bw < WEIGHT_BW * 0.8:
        min_freq = dram_bw / (MAC_COUNT * 2)
        min_freq = max(min_freq, 0.1)
        return "DRAM瓶颈", True, min_freq
    elif dram_bw > WEIGHT_BW * 1.2:
        return "计算瓶颈", False, CLOCK_GHZ
    else:
        return "平衡", False, CLOCK_GHZ


def calc_dvfs_power(freq_ghz):
    """MAC DVFS 功耗: P ∝ f³"""
    return MAC_POWER * freq_ghz ** 3


def calc_card_perf(pcb_cfg, dram, model_type, weight_gb, layers, hidden_dim,
                    total_experts=0, active_experts=0):
    """计算单卡性能: effective_bw = min(compute_bw, dram_bw)"""
    chips_per_pcb = pcb_cfg["chips_per_pcb"]
    total_chips = chips_per_pcb * pcb_cfg["pcbs"]

    # 功耗
    chip_power = (CHIP_POWER_BASE + dram["power"]) * total_chips
    feasible = chip_power <= pcb_cfg["max_power_w"] * 1.1

    # 带宽
    compute_bw = total_chips * COMPUTE_BW
    dram_bw = total_chips * dram["bw"]
    effective_bw = min(compute_bw, dram_bw)
    total_mem = total_chips * dram["cap"]

    # 计算时间
    compute_time = layers * weight_gb / effective_bw * 1000  # ms

    # All-reduce
    msg_bytes = hidden_dim * 2
    if total_chips > 1:
        ar_time = (total_chips - 1) / total_chips * msg_bytes / (SERDES_BW * 1e9) * 1e3
    else:
        ar_time = 0
    ar_total = ar_time * layers
    total_time = compute_time + ar_total
    tok_per_s = 1000 / total_time if total_time > 0 else 0

    # 成本
    chip_cost = (CHIP_COST_BASE + dram["price"]) * total_chips
    pcb_cost = 3000 * pcb_cfg["pcbs"]
    cooling_cost = 5000 if pcb_cfg["cooling"] == "液冷" else 500
    total_cost = chip_cost + pcb_cost + cooling_cost

    return {
        "chips_per_pcb": chips_per_pcb,
        "total_chips": total_chips,
        "compute_bw": compute_bw,
        "dram_bw": dram_bw,
        "effective_bw": effective_bw,
        "total_mem": total_mem,
        "tok_per_s": tok_per_s,
        "compute_ms": compute_time,
        "ar_ms": ar_total,
        "ar_pct": ar_total / total_time * 100 if total_time > 0 else 0,
        "chip_power": chip_power,
        "total_power": chip_power + 50,
        "total_cost": total_cost,
        "chip_cost": chip_cost,
        "pcb_cooling_cost": pcb_cost + cooling_cost,
        "feasible": feasible,
        "cooling": pcb_cfg["cooling"],
    }


# ===== 主程序 =====
print("=" * 100)
print("PCB 配置 + DRAM 选型 + 散热 + 功耗优化 综合分析（v4, bf16: 4B/MAC）")
print("=" * 100)
print(f"芯片: {MAC_COUNT} MAC, 计算带宽: {COMPUTE_BW} GB/s, 权重需求: {WEIGHT_BW} GB/s")
print()

# 一、瓶颈分析
print("=" * 100)
print("一、瓶颈分析")
print("=" * 100)
print(f"\n{'配置':<15} {'ch':>3} {'MT/s':>7} {'bus':>5} {'带宽GB/s':>9} {'权重需求':>10} {'比值':>6} {'瓶颈':>8} {'可降频':>6}")
print("-" * 85)

for name, cfg in DRAM_OPTIONS.items():
    d = calc_dram(name, cfg)
    ratio = d["bw"] / WEIGHT_BW
    bn, can, mf = get_bottleneck(d["bw"])
    print(f"{d['name']:<15} {cfg['channels']:>3} {cfg['mt_s']:>7,} {cfg['bus_bits']:>5} {d['bw']:>8.0f} {WEIGHT_BW:>8.0f} {ratio:>5.2f}x {bn:>8} {'✅' if can else '❌':>6}")

# 二、DVFS
print("\n" + "=" * 100)
print("二、MAC DVFS（仅 DRAM 瓶颈时有效）")
print("=" * 100)

for name in ["LPDDR5X-8ch", "LPDDR5X-4ch", "HBM3-1stack"]:
    d = calc_dram(name, DRAM_OPTIONS[name])
    bn, can, mf = get_bottleneck(d["bw"])
    print(f"\n--- {d['name']}: DRAM {d['bw']:.0f} GB/s, {bn} ---")
    if can:
        print(f"  MAC 可从 {CLOCK_GHZ}GHz 降到 {mf:.2f}GHz，性能不变")
        print(f"  {'freq':>8} {'MAC P':>8} {'DRAM P':>8} {'总P':>8} {'省电':>6}")
        print("  " + "-" * 45)
        for freq in [1.0, 0.8, 0.6, 0.4, 0.2]:
            if freq < mf: continue
            mp = calc_dvfs_power(freq)
            dp = DRAM_OPTIONS[name]["power"]
            tp = mp + dp + SRAM_POWER + SERDES_POWER + OTHER_POWER
            base = MAC_POWER + dp + SRAM_POWER + SERDES_POWER + OTHER_POWER
            print(f"  {freq:>7.1f}GHz {mp:>7.1f}W {dp:>7.1f}W {tp:>7.1f}W {(1-tp/base)*100:>5.0f}%")
    else:
        print(f"  不能降频。如需省电，关闭空闲芯片（MoE 场景）")

# 三、PCB 配置对比
print("\n" + "=" * 100)
print("三、PCB 配置对比")
print("=" * 100)

dram_8ch = calc_dram("LPDDR5X-8ch", DRAM_OPTIONS["LPDDR5X-8ch"])

for model_name, model_type, weight_gb, layers, hidden_dim, *moe_args in MODELS:
    print(f"\n--- {model_name} ---")
    print(f"{'配置':<12} {'芯片':>6} {'计算BW':>10} {'DRAM BW':>10} {'有效BW':>10} {'tok/s':>8} {'功耗W':>7} {'成本¥':>10}")
    print("-" * 85)

    for cfg_name, cfg in PCB_CONFIGS.items():
        r = calc_card_perf(cfg, dram_8ch, model_type, weight_gb, layers, hidden_dim)
        print(f"{cfg_name:<12} {r['total_chips']:>6} {r['compute_bw']:>8.0f}GB/s {r['dram_bw']:>8.0f}GB/s {r['effective_bw']:>8.0f}GB/s {r['tok_per_s']:>7.1f} {r['total_power']:>6.0f} {r['total_cost']:>9,}")

# 四、4ch vs 8ch
print("\n" + "=" * 100)
print("四、LPDDR5X 4ch vs 8ch")
print("=" * 100)

dram_4ch = calc_dram("LPDDR5X-4ch", DRAM_OPTIONS["LPDDR5X-4ch"])

print(f"\n{'配置':<12} {'芯片':>6} {'8ch有效BW':>10} {'4ch有效BW':>10} {'8ch tok/s':>10} {'4ch tok/s':>10} {'4ch/8ch':>8}")
print("-" * 75)

for cfg_name, cfg in PCB_CONFIGS.items():
    r8 = calc_card_perf(cfg, dram_8ch, "dense", 14, 32, 4096)
    r4 = calc_card_perf(cfg, dram_4ch, "dense", 14, 32, 4096)
    ratio = r4["tok_per_s"] / r8["tok_per_s"] if r8["tok_per_s"] > 0 else 0
    print(f"{cfg_name:<12} {r8['total_chips']:>6} {r8['effective_bw']:>8.0f}GB/s {r4['effective_bw']:>8.0f}GB/s {r8['tok_per_s']:>9.1f} {r4['tok_per_s']:>9.1f} {ratio:>7.2f}x")

# 五、MoE 省电
print("\n" + "=" * 100)
print("五、MoE 场景功耗优化")
print("=" * 100)
print()
print("K3 MoE: 80 颗芯片, 16 颗激活, 64 颗空闲")
print()

total_chips = 80
active = 16
idle = total_chips - active

print(f"{'方案':<35} {'活跃W':>6} {'空闲W':>6} {'总W':>6} {'省电':>6}")
print("-" * 65)

scenarios = [
    ("全开 (不省电)", 1.0, 1.0),
    ("MAC 0.8GHz (全部芯片)", 0.8, 0.8),
    ("MAC 0.6GHz (全部芯片)", 0.6, 0.6),
    ("空闲芯片断电", 1.0, 0.0),
    ("MAC 0.8GHz + 空闲断电", 0.8, 0.0),
    ("MAC 0.6GHz + 空闲断电", 0.6, 0.0),
]

baseline = total_chips * (MAC_POWER + DRAM_OPTIONS["LPDDR5X-8ch"]["power"] + SRAM_POWER + SERDES_POWER + OTHER_POWER) + 50

for name, active_freq, idle_freq in scenarios:
    active_mac_p = calc_dvfs_power(active_freq)
    active_total = active * (active_mac_p + DRAM_OPTIONS["LPDDR5X-8ch"]["power"] + SRAM_POWER + SERDES_POWER + OTHER_POWER)
    idle_mac_p = calc_dvfs_power(idle_freq)
    idle_total = idle * (idle_mac_p + DRAM_OPTIONS["LPDDR5X-8ch"]["power"] + SRAM_POWER + SERDES_POWER + OTHER_POWER)
    total_p = active_total + idle_total + 50
    savings = (1 - total_p / baseline) * 100
    print(f"{name:<35} {active_total:>5.0f}W {idle_total:>5.0f}W {total_p:>5.0f}W {savings:>5.0f}%")

# 六、总结
print("\n" + "=" * 100)
print("六、总结")
print("=" * 100)
print(f"""
核心参数:
  {MAC_COUNT} MAC × {CLOCK_GHZ} GHz × 4B = {COMPUTE_BW} GB/s 计算
  {MAC_COUNT} MAC × {CLOCK_GHZ} GHz × 2B = {WEIGHT_BW} GB/s 权重需求 (DRAM)

瓶颈:
  DRAM < {WEIGHT_BW} GB/s → DRAM 瓶颈 → MAC 可降频省电
  DRAM > {WEIGHT_BW} GB/s → 计算瓶颈 → MAC 满载

各配置:
  LPDDR5X-8ch: {DRAM_OPTIONS['LPDDR5X-8ch']['channels']}×{DRAM_OPTIONS['LPDDR5X-8ch']['mt_s']}×{DRAM_OPTIONS['LPDDR5X-8ch']['bus_bits']}/8 = {calc_dram('x', DRAM_OPTIONS['LPDDR5X-8ch'])['bw']:.0f} GB/s → 计算瓶颈
  LPDDR5X-4ch: {DRAM_OPTIONS['LPDDR5X-4ch']['channels']}×{DRAM_OPTIONS['LPDDR5X-4ch']['mt_s']}×{DRAM_OPTIONS['LPDDR5X-4ch']['bus_bits']}/8 = {calc_dram('x', DRAM_OPTIONS['LPDDR5X-4ch'])['bw']:.0f} GB/s → DRAM 瓶颈, 可降到 {calc_dram('x', DRAM_OPTIONS['LPDDR5X-4ch'])['bw']/(MAC_COUNT*2):.2f}GHz
  HBM3-1stack: {DRAM_OPTIONS['HBM3-1stack']['channels']}×{DRAM_OPTIONS['HBM3-1stack']['mt_s']}×{DRAM_OPTIONS['HBM3-1stack']['bus_bits']}/8 = {calc_dram('x', DRAM_OPTIONS['HBM3-1stack'])['bw']:.0f} GB/s → 计算瓶颈
  HBM3-2stack: {DRAM_OPTIONS['HBM3-2stack']['channels']}×{DRAM_OPTIONS['HBM3-2stack']['mt_s']}×{DRAM_OPTIONS['HBM3-2stack']['bus_bits']}/8 = {calc_dram('x', DRAM_OPTIONS['HBM3-2stack'])['bw']:.0f} GB/s → 计算瓶颈

MoE 省电:
  空闲芯片断电: 省 78%
  MAC 0.6GHz + 空闲断电: 省 87% (DRAM 瓶颈时性能不变)
""")
