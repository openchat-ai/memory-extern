#!/usr/bin/env python3
"""
K3 推理设备 · 最小可行配置 · 成本精算
架构：GEMV die + 裸 NAND die 合封 + DDR4 预取缓冲（无 SRAM）
存储：流式读取，不需要全部权重常驻高速内存
"""
import math

print("=" * 70)
print("K3 MoE 推理设备 · 最小可行配置成本核算")
print("架构：GEMV die + 片内合封 NAND + 预取流水线（无 SRAM）")
print("=" * 70)

# ===== K3 模型参数（k3-verdict.md 实测）=====
K3_WEIGHT_GB    = 1561     # 权重总量
K3_TRAFFIC_GB   = 25.83   # 每 token 激活流量
K3_OPS_G        = 113.6   # 每 token 计算量 GOPS

# ===== NAND 裸片价格（当前行情，多档对比）=====
# 来源：TrendForce 2026Q2-Q3 现货/合约价区间
# 单位：¥/die（每颗 die 的裸片批发价，未封装未测试）
nand_prices = {
    "512Gb TLC (64GB)":  {"gb": 64,  "price_cny": 72},    # ~$10/die 中位
    "512Gb TLC (64GB)高": {"gb": 64,  "price_cny": 108},   # ~$15/die 高位
    "QLC 1Tb (128GB)":   {"gb": 128, "price_cny": 130},   # ~$18/die
}

print(f"\n--- K3 模型需求 ---")
print(f"权重总量       : {K3_WEIGHT_GB:,} GB")
print(f"每 token 流量  : {K3_TRAFFIC_GB} GB")
print(f"每 token 计算  : {K3_OPS_G:.1f} GOPS")

# ===== 方案一：最小可行（1 颗 GEMV die + 最少 NAND）=====
print(f"\n{'='*70}")
print(f"方案 A：最小可行配置（单 die，跑通优先）")
print(f"{'='*70}")

# 1 颗 GEMV die：128 MAC @ 500MHz（保守频率，成熟工艺可跑）
mac_count_a   = 128
clock_ghz_a   = 0.5
compute_gops_a = mac_count_a * clock_ghz_a * 4  # int4 SIMD 4 ops/cycle
fetch_bw_a    = mac_count_a * clock_ghz_a * 0.5  # int4: 0.5B/cycle/MAC

ts_compute = compute_gops_a / K3_OPS_G
ts_nvme_min = fetch_bw_a / K3_TRAFFIC_GB  # 如果 NAND 是瓶颈

# NAND 数量：容量驱动
for pname, cfg in nand_prices.items():
    n_dies = math.ceil(K3_WEIGHT_GB / cfg["gb"]) if 'math' else 0
    # 需要 import math
import math
for pname, cfg in nand_prices.items():
    n_dies = math.ceil(K3_WEIGHT_GB / cfg["gb"])
    cost_nand = n_dies * cfg["price_cny"]
    print(f"  {pname:<22} : {n_dies:>3} 颗 × ¥{cfg['price_cny']} = ¥{cost_nand:,}")

# 用最便宜的算
cheapest_name = min(nand_prices, key=lambda x: nand_prices[x]["price_cny"] / nand_prices[x]["gb"])
cheapest = nand_prices[cheapest_name]
n_nand_a = math.ceil(K3_WEIGHT_GB / cheapest["gb"])
nand_cost_a = n_nand_a * cheapest["price_cny"]

# 其他部件
gemv_die_cost = 500      # ¥/颗（14nm 小逻辑 die 量产）
ddr4_buffer   = 300      # ¥（DDR4 4GB 颗粒做预取落地）
pcb_power     = 800      # ¥（基板+供电+接口）
packaging     = 1_500    # ¥（MCM 合封）

total_a = gemv_die_cost + nand_cost_a + ddr4_buffer + pcb_power + packaging
print(f"\n--- 方案 A 成本 ---")
print(f"GEMV die          : ¥{gemv_die_cost:,}")
print(f"NAND die ×{n_nand_a} ({cheapest_name}) : ¥{nand_cost_a:,}")
print(f"DDR4 缓冲         : ¥{ddr4_buffer:,}")
print(f"基板/封装/PCB     : ¥{pcb_power + packaging:,}")
print(f"合计              : ¥{total_a:,}")

# 性能估算
eff_ts = min(fetch_bw_a, compute_gops_a / K3_OPS_G) 
print(f"预期吞吐(理论): ~{fetch_bw_a/K3_TRAFFIC_GB:.0f} t/s（受限于单 die 带宽）")

# ===== 方案 B：推荐配置（4 颗 GEMV die 并行 + 充足 NAND）=====
print(f"\n{'='*70}")
print(f"方案 B：推荐配置（4 颗 GEMV die 并行，带宽充足）")
print(f"{'='*70}")

n_dice_b      = 4
mac_count_b   = 128 * n_dice_b
clock_ghz_b   = 0.5
compute_gops_b = mac_count_b * clock_ghz_b * 4
fetch_bw_b    = mac_count_b * clock_ghz_b * 0.5

# NAND：用 16GB TLC die，数量按容量+带宽双达标
n_nand_b = max(math.ceil(K3_WEIGHT_GB / 64), 24)  # 至少 24 颗保证并行带宽
nand_cost_b = n_nand_b * 72

ddr4_buffer_b = 800   # 8GB DDR4
pcb_b = 1500
pkg_b = 3000  # 4 颗 MCM 封装

total_b = gemv_die_cost * n_dice_b + nand_cost_b + ddr4_buffer_b + pcb_b + pkg_b

print(f"GEMV die ×{n_dice_b}       : ¥{gemv_die_cost * n_dice_b:,}")
print(f"NAND die ×{n_nand_b}      : ¥{nand_cost_b:,}")
print(f"DDR4 缓冲         : ¥{ddr4_buffer_b:,}")
print(f"基板/封装/PCB     : ¥{pcb_b + pkg_b:,}")
print(f"合计              : ¥{total_b:,}")

# 吞吐估算
nvme_agg = n_nand_b * 7  # GB/s 假设每颗 NAND die 通道贡献 ~7GB/s 等效读取
k3_ts_b = nvme_agg / K3_TRAFFIC_GB if nvme_agg > 0 else 0
# 但实际上 NAND die 直连不走 NVMe 协议，带宽由控制器设计决定
# 保守估计：每 4 颗 NAND die 一条 8GB/s 通道
read_channels = n_nand_b // 4
k3_ts_est = read_channels * 8 / K3_TRAFFIC_GB

print(f"\n--- 方案 B 性能 ---")
print(f"聚合取指带宽 : {fetch_bw_b:.0f} GB/s")
print(f"NVMe 等效吞吐: ~{k3_ts_est:.0f} t/s（{read_channels} 条读通道）")
print(f"功耗         : ~{n_dice_b * 28 + 50:.0f} W")

# ===== 对标 =====
h200_k3 = 4800 / K3_TRAFFIC_GB
h200_cards_needed = math.ceil(K3_MODEL_GB / 141)  # H200 141GB each
h200_total = h200_cards_needed * 350_000

print(f"\n--- 对标 H200 ---")
print(f"H200 装 K3 需要 {h200_cards_needed} 张 × ¥35 万 = ¥{h200_total:,}")
print(f"H200 吞吐     : {4800/K3_TRAFFIC_GB:.0f} t/s")
print(f"你的方案 A    : ¥{total_a:,} | 你的方案 B    : ¥{total_b:,}")
