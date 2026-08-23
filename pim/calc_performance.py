#!/usr/bin/env python3
"""
GEMV 芯片性能计算器 v4
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
SERDES_BW = SERDES_LANES * SERDES_RATE_GBPS / 8  # 50 GB/s/chip


# ===== 内存配置（全部用公式计算，无硬编码）=====
# 带宽公式: channels × mt_s × bus_bits / 8 / 1e3 (GB/s)
# 容量公式: channels × die_gb (GB)
# 成本公式: capacity × price_per_gb (¥)

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

# ===== 竞品规格 =====
COMPETITORS = {
    "H100": {"bw": 3350, "mem": 80, "power": 700, "cost": 250000},
    "H200": {"bw": 4800, "mem": 141, "power": 700, "cost": 350000},
}

# ===== 功耗模型 =====
MAC_POWER = 20  # W @ 1GHz
SRAM_POWER = 2  # W
SERDES_POWER = 2  # W
OTHER_POWER = 1  # W
CHIP_POWER_BASE = MAC_POWER + OTHER_POWER  # 21W (不含 DRAM)


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
        min_freq = dram_bw / (MAC_COUNT * 2)  # 2B 权重/MAC
        min_freq = max(min_freq, 0.1)
        return "DRAM瓶颈", True, min_freq
    elif dram_bw > WEIGHT_BW * 1.2:
        return "计算瓶颈", False, CLOCK_GHZ
    else:
        return "平衡", False, CLOCK_GHZ


def calc_dvfs_power(freq_ghz):
    """MAC DVFS 功耗: P ∝ f³"""
    return MAC_POWER * freq_ghz ** 3


def calc_perf(n_chips, dram_bw, weight_gb, layers):
    """性能计算: effective_bw = min(compute_bw, dram_bw)"""
    compute_bw = n_chips * COMPUTE_BW
    dram_total = n_chips * dram_bw
    effective_bw = min(compute_bw, dram_total)
    tok_per_s = 1 / (layers * weight_gb / effective_bw) if effective_bw > 0 else 0
    return {
        "compute_bw": compute_bw, "dram_bw": dram_total,
        "effective_bw": effective_bw, "tok_per_s": tok_per_s,
    }


def calc_card_perf(dram, n_chips=28):
    """计算单卡规格"""
    chip_power = (CHIP_POWER_BASE + dram["power"]) * n_chips
    chip_cost = (500 + dram["price"]) * n_chips
    return {"total_power": chip_power + 50, "total_cost": chip_cost}


# ===== 主程序 =====
print("=" * 100)
print("GEMV 芯片性能计算器 v4（bf16: 4B/MAC，全部公式计算）")
print("=" * 100)
print(f"芯片: {MAC_COUNT} MAC, 计算带宽: {COMPUTE_BW} GB/s, 权重需求: {WEIGHT_BW} GB/s")
print()

# 一、内存配置对比
print("=" * 100)
print("一、内存配置对比（全部公式计算）")
print("=" * 100)

print(f"\n{'配置':<15} {'ch':>3} {'MT/s':>7} {'bus':>5} {'带宽GB/s':>9} {'容量GB':>7} {'成本¥':>8} {'功耗W':>5} {'瓶颈':>8} {'可降频':>6}")
print("-" * 95)

for name, cfg in DRAM_OPTIONS.items():
    d = calc_dram(name, cfg)
    bn, can, mf = get_bottleneck(d["bw"])
    print(f"{d['name']:<15} {cfg['channels']:>3} {cfg['mt_s']:>7,} {cfg['bus_bits']:>5} {d['bw']:>8.0f} {d['cap']:>6.0f} {d['price']:>7,} {d['power']:>5.0f} {bn:>8} {'✅' if can else '❌':>6}")

# 二、性能对比
print("\n" + "=" * 100)
print("二、性能对比 (28 芯片)")
print("=" * 100)

for model_name, weight_gb, layers in [("Llama-7B bf16", 14, 32), ("Llama-70B bf16", 140, 80)]:
    print(f"\n--- {model_name} ---")
    print(f"{'配置':<15} {'计算BW':>10} {'DRAM BW':>10} {'有效BW':>10} {'tok/s':>8} {'vs H100':>8} {'成本':>10} {'功耗':>8}")
    print("-" * 85)
    
    for name, cfg in DRAM_OPTIONS.items():
        d = calc_dram(name, cfg)
        r = calc_perf(28, d["bw"], weight_gb, layers)
        card = calc_card_perf(d, 28)
        h100_tps = 1 / (layers * weight_gb / COMPETITORS["H100"]["bw"])
        ratio = r["tok_per_s"] / h100_tps if h100_tps > 0 else 0
        print(f"{d['name']:<15} {r['compute_bw']:>8.0f}GB/s {r['dram_bw']:>8.0f}GB/s {r['effective_bw']:>8.0f}GB/s {r['tok_per_s']:>7.2f} {ratio:>7.2f}x ¥{card['total_cost']:>9,} {card['total_power']:>7.0f}W")

# 三、MoE 对比
print("\n" + "=" * 100)
print("三、MoE 模型对比 (K3, 224 芯片)")
print("=" * 100)

# ===== K3 实测参数（notes/k3-verdict.md，2026-08-23 safetensors 全量扫描）=====
K3 = dict(
    n_layers_total=93,
    n_moe_layers=92,            # layer0 为 dense
    n_expert=896,
    n_expert_used=16,
    expert_mb_per_layer_quantized=17.55,   # 落盘字节实测（mxfp4-pack ≈1.82bit/w）
    activated_gb_per_token=25.83,          # = 92层 × 16 × 17.55MB —— per-token 总量
)
assert abs(K3["activated_gb_per_token"] -
           K3["n_moe_layers"] * K3["n_expert_used"] *
           K3["expert_mb_per_layer_quantized"] / 1000) < 0.01   # 十进制口径，与带宽公式一致
k3_activated_total = K3["activated_gb_per_token"]   # ⚠️ 勿再乘层数（旧公式双重计数）
h200_tps = COMPETITORS["H200"]["bw"] / k3_activated_total

print(f"\n{'配置':<15} {'拆分':<8} {'有效BW':>10} {'tok/s':>8} {'vs H200':>8}")
print("-" * 55)

for name, cfg in DRAM_OPTIONS.items():
    d = calc_dram(name, cfg)
    
    # 不拆分: 16 颗工作
    eff1 = 16 * d["bw"]
    tps1 = eff1 / k3_activated_total if eff1 > 0 else 0

    # 拆分: 224 颗工作
    eff2 = 224 * d["bw"]
    tps2 = eff2 / k3_activated_total if eff2 > 0 else 0
    
    print(f"{d['name']:<15} {'❌ 不拆':<8} {eff1:>8.0f}GB/s {tps1:>7.2f} {tps1/h200_tps:>7.2f}x")
    print(f"{'':<15} {'✅ 拆分':<8} {eff2:>8.0f}GB/s {tps2:>7.2f} {tps2/h200_tps:>7.2f}x")

# 四、DVFS
print("\n" + "=" * 100)
print("四、MAC DVFS（仅 DRAM 瓶颈时有效）")
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
        # 整卡降频运行点：性能不变，按最低可行频率计整卡功耗与能效
        n_chips = 224
        mp_min = calc_dvfs_power(mf)
        chip_w = mp_min + d["power"] + SRAM_POWER + SERDES_POWER + OTHER_POWER
        card_w = chip_w * n_chips + 50
        eff_bw = n_chips * d["bw"]
        tps = eff_bw / k3_activated_total
        ee = tps / (card_w / 1000)
        h200_ee = h200_tps / (700 / 1000)
        print(f"  整卡@{mf:.2f}GHz(224颗): {card_w:.0f}W | K3 {tps:.2f} t/s"
              f" | 能效 {ee:.2f} t/(s·kW) (H200单卡 {h200_ee:.2f}, 比值 {ee/h200_ee:.2f}x)")
    else:
        print(f"  不能降频。如需省电，关闭空闲芯片（MoE 场景）")
        # 整卡满载能效（计算瓶颈）
        n_chips = 224
        chip_w = CHIP_POWER_BASE + SRAM_POWER + SERDES_POWER + d["power"]
        card_w = chip_w * n_chips + 50
        eff_bw = n_chips * d["bw"]
        tps = eff_bw / k3_activated_total
        ee = tps / (card_w / 1000)
        h200_ee = h200_tps / (700 / 1000)
        print(f"  整卡满载(224颗): {card_w:.0f}W | K3 {tps:.2f} t/s"
              f" | 能效 {ee:.2f} t/(s·kW) (H200单卡 {h200_ee:.2f}, 比值 {ee/h200_ee:.2f}x)")

# 五、总结
print("\n" + "=" * 100)
print("五、总结")
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
""")
