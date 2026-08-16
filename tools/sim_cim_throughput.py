#!/usr/bin/env python3
"""sim_cim_throughput.py — die 级内存计算吞吐模型（流片规格探索）

回答的问题：一个（或一组）内存计算 die 能不能撑起 10 tok/s？卡在哪个闸？
与 sim_stream.py 的区别：那边问"要搬多少字节"，这里问"CIM die 要多大、
多快、存什么格式"。

三道闸（串联，取最小）：
  1. 容量闸：trunk + 专家缓存必须常驻阵列。阵列容量 = die 面积 × 存储密度
     （SRAM 模拟 cell 密度低，NAND 模拟 cell 密度高）。装不下 → 多 die / 换介质。
  2. ADC 吞吐闸：每 token 要 1.95G 次 ADC 转换（= 总权重 / group=32），
     die 每秒能转 = 列数 × 每列转换率。SAR ADC 转换时间 ≈ bits × 时钟周期。
  3. host 闸：非 matmul（路由/注意力 QK/PV/RMSNorm/GLU/残差/部分和）留在 CPU，
     需要的 GFLOP/s 必须 host 给得起。

用法：python3 sim_cim_throughput.py
"""
GB = 1 << 30
G = 1e9

# ---- 模型账本（上游实测 + 本仓库 pim/ 推导）----
TRUNK_PARAMS = 56.7e9          # always-active 参数数
TRUNK_BF16_GB = TRUNK_PARAMS * 2 / GB
TRUNK_MXFP4_GB = TRUNK_PARAMS * 0.531 / GB   # 0.5 权重字节 + 1/32 scale 字节
GROUP = 32
CONV_PER_TOKEN = 1.94964246e9  # trunk 1.772G + 专家 miss 0.178G（见 pim/ 推导）
EXPERTS_CACHE_GB = 96.0        # 专家缓存预算（可调）
HOST_NONMATMUL_GF = 40.0       # host 非 matmul GFLOP/token（估：路由+注意力+norm）

# ---- 介质/阵列参数（保守可调）----
# 存储密度：模拟 cell 每 die 能存多少 GB（SRAM 4bit cell ~0.1-0.5 GB/die；
#  DRAM 近存 ~8-32 GB/die；NAND 模拟 ~64-256 GB/die）
MEDIA = {
    "SRAM 模拟cell": 0.25,      # GB/die
    "DRAM 近存":     16.0,
    "NAND 模拟":    128.0,
}
DIE_AREA_MM2 = 400.0

# SAR ADC：转换时间 ≈ bits 个时钟周期；时钟 1GHz → 每 bit ~1ns
ADC_CLK_GHZ = 1.0
# 每 die 列数（= 并行 ADC 数；受 die 面积限制，量级估计）
ADC_COLS_PER_DIE = 1024


def adc_rate(bits):
    # 每秒每列转换次数：1/(bits×clk)
    return 1.0 / (bits / ADC_CLK_GHZ / 1e9)


def main():
    print("die 级内存计算吞吐模型（流片规格探索）")
    print(f"账本: trunk {TRUNK_BF16_GB:.1f}GB(bf16) / {TRUNK_MXFP4_GB:.1f}GB(MXFP4)  "
          f"· 专家缓存 {EXPERTS_CACHE_GB:.0f}GB · 每 token {CONV_PER_TOKEN/G:.2f}G 转换\n")

    print("闸1 容量：trunk 常驻格式 × 介质 → 需要几颗 die")
    print(f"  {'介质':<12} {'密度GB/die':>10} {'trunk bf16需':>12} {'trunk MXFP4需':>14}")
    for name, gb in MEDIA.items():
        print(f"  {name:<12} {gb:>10.1f} {((TRUNK_BF16_GB+EXPERTS_CACHE_GB)/gb):>10.1f}颗 "
              f"{((TRUNK_MXFP4_GB+EXPERTS_CACHE_GB)/gb):>10.1f}颗")
    print("  （注意：多 die 需跨 die 部分和聚合，串行化开销未建模）\n")

    print("闸2 ADC 吞吐：单颗 die，位数 × 列数 → 每秒转换 → 支持 tok/s")
    print(f"  {'ADC位':>5} {'速率MS/s/列':>11} {'1024列 Gconv/s':>14} {'tok/s':>8}")
    for bits in (8, 10, 12):
        r = adc_rate(bits) / 1e6
        cap = ADC_COLS_PER_DIE * adc_rate(bits)
        print(f"  {bits:>5} {r:>11.0f} {cap/G:>14.2f} {cap/CONV_PER_TOKEN:>8.1f}")
    print("  （每 token 1.95G 转换 = 56.7G trunk/32 + 专家 miss；SAR 转换时间≈bits×1ns\n"
          "    未建模：模拟累加 settle 时间、DAC 驱动、跨 die 聚合——真实只低不高）\n")

    print("闸3 host：非 matmul 负载")
    for gf in (20, 40, 80):
        print(f"  host {gf} GFLOP/token @10tok/s = {gf*10/1000:.1f} TFLOP/s")

    print("\n== 现实 die 数（1/2/4颗）下的可达 tok/s = min(ADC吞吐, host) ==")
    print(f"  {'die数':>5} {'介质':<12} {'格式':<8} {'10bit':>8} {'12bit':>8}  "
          f"{'容量够?':>10}")
    for n_die in (1, 2, 4):
        for name, gb in MEDIA.items():
            for fmt, need in (("bf16", TRUNK_BF16_GB), ("MXFP4", TRUNK_MXFP4_GB)):
                fit = n_die * gb >= need + EXPERTS_CACHE_GB
                t10 = n_die * ADC_COLS_PER_DIE * adc_rate(10) / CONV_PER_TOKEN
                t12 = n_die * ADC_COLS_PER_DIE * adc_rate(12) / CONV_PER_TOKEN
                print(f"  {n_die:>5} {name:<12} {fmt:<8} {t10:>8.1f} {t12:>8.1f}  "
                      f"{'OK' if fit else 'NO':>10}")

    print("\n== 判决 ==")
    print("  1. SRAM 模拟cell：trunk 装不下（800/500 颗 die），只配做专家侧/小模型")
    print("  2. DRAM 近存：bf16 要 13 颗、MXFP4 要 8 颗——接近 HBM 堆叠量级，可行但贵")
    print("  3. NAND 模拟：1-2 颗 die 装得下，上限被 ADC 吞吐锁在 ~50 tok/s（12bit）")
    print("     —— 单 die 流片的唯一现实介质；10bit 比 12bit 多 20% 吞吐")
    print("  4. 精度侧（pim/sim_cim.c）：10bit 已是理想下界 4e-3 的契约线，")
    print("     器件噪声（0.5% cell 变异）→ 1.2e-2，加位数也救不回（噪声主导）")
    print("     → 流片矛盾：NAND 模拟 cell 噪声大（>0.5% 常见），10bit ADC 的")
    print("     吞吐优势被 cell 噪声的精度劣化抵消——要保住 ~1e-3 得 <0.1% cell")
    print("     变异，这基本排除了 NAND 模拟，只剩 SRAM/DRAM 数字 cell")


if __name__ == "__main__":
    main()
