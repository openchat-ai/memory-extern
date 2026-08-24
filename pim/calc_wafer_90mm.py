#!/usr/bin/env python3
"""
90mm 晶圆 + 14nm FinFET + 权重片上ROM 架构计算器
诚实评估：能装什么、不能装什么、需要多大才能装 K3
"""
import math

print("=" * 70)
print("90mm 晶圆 · 14nm · 片上权重 ROM · 容量与性能计算")
print("=" * 70)

# ===== 晶圆物理 =====
DIA_MM     = 90
TOTAL_AREA = math.pi * (DIA_MM/2)**2
EDGE_EXCL  = 3
USABLE     = math.pi * ((DIA_MM/2) - EDGE_EXCL)**2

print(f"\n--- 晶圆 ---")
print(f"直径 {DIA_MM}mm | 总面积 {TOTAL_AREA:.0f} | 可用 {USABLE:.0f} mm²")

# ===== 工艺参数（14nm FinFET）=====
T_PER_MM2      = 30_000_000
ROM_BITS_MM2   = T_PER_MM2 / 1   # 掩膜 ROM：1T/bit
ROM_GB_MM2     = ROM_BITS_MM2 / 8 / 1e9

# ===== 面积分配 =====
N_CLUSTERS     = 8
CLUSTER_AREA   = 25.0
MAC_AREA       = N_CLUSTERS * CLUSTER_AREA
NOC_FRAC       = 0.12
IO_AREA        = 40.0

ROM_AREA       = USABLE - MAC_AREA - USABLE*NOC_FRAC - IO_AREA
if ROM_AREA < 0: ROM_AREA = 0

# ===== ROM 容量 =====
ROM_CAP_GB = ROM_AREA * ROM_GB_MM2

print(f"\n--- 面积分配 ---")
print(f"MAC 集群区 : {MAC_AREA:.0f} mm² ({N_CLUSTERS} 组)")
print(f"NOC        : {USABLE*NOC_FRAC:.0f} mm²")
print(f"I/O        : {IO_AREA:.0f} mm²")
print(f"ROM 区     : {ROM_AREA:.0f} mm² → {ROM_CAP_GB:.1f} GB")

# ===== 能装什么模型？=====
models = [
    ("Qwen3.8-27B @ Q3_K_S", 12.57),
    ("Llama-70B @ Q3_K_S",   31.0),
    ("Qwen3-30B-A3B @ mxfp4", 18.6),
    ("DeepSeek-V3 @ mxfp4",  377.0),
    ("K3-MoE @ mxfp4",       1561.0),
]

print(f"\n--- 能装哪些模型 ---")
for name, gb in models:
    mark = "✅" if gb <= ROM_CAP_GB else "❌"
    pct = f"({100*gb/ROM_CAP_GB:.0f}%)" if gb <= ROM_CAP_GB else f"(需 {gb/ROM_CAP_GB:.0f} 倍面积)"
    print(f"  {mark} {name:<28} {gb:>7.1f} GB  {pct}")

# ===== 性能计算（只算能装的）=====
CLOCK_GHZ = 1.0
INT4_B_PER_MAC_CYCLE = 0.5  # int4 SIMD: 2B 取指 = 4 权重 → 每 op 0.5B

print(f"\n--- 吞吐计算（按可运行的最大模型）---")

for name, model_gb in [("27B-dense@Q3KS", 12.57), ("30B-A3B@mxfp4", 18.6)]:
    if model_gb > ROM_CAP_GB:
        print(f"  {name}: 装不下，跳过")
        continue
    # DRAM(ROM) 读出带宽：64 bank × 64bit × 250MHz ÷ 8
    cluster_banks = 64
    cluster_bw = N_CLUSTERS * cluster_banks * 64 * 250e6 / 8 / 1e9  # GB/s
    
    # 密集模型：每 token 全读
    ts_fetch = cluster_bw / model_gb
    # 计算上限
    ts_compute = TOTAL_MACS_placeholder if False else 0  # placeholder
    
    # MAC 数定标
    macs_per_cluster = int(cluster_bw / INT4_B_PER_MAC_CYCLE)
    
    print(f"\n  [{name}]")
    print(f"  模型大小   : {model_gb:.1f} GB")
    print(f"  聚合 ROM BW: {cluster_bw:.0f} GB/s")
    print(f"  理论 t/s   : {ts_fetch:.0f}")
    
# ===== K3 需要多大晶圆？=====
print(f"\n{'='*70}")
print(f"K3-MoE 需要的晶圆尺寸反推")
print(f"{'='*70}")

k3_rom_mm2 = K3_MODEL_GB / ROM_GB_MM2 if 'K3_MODEL_GB' in dir() else 1561 / 3.75
k3_total_mm2 = k3_rom_mm2 + 200 + 600  # ROM + MAC + NOC/IO
k3_min_dia = 2 * math.sqrt(k3_total_mm2 / math.pi)

print(f"K3 权重 ROM 面积需求 : {1561/3.75:.0f} mm²")
print(f"+ MAC/互连/I/O 开销  : ~800 mm²")
print(f"最小可用面积         : ~{1561/3.75 + 800:.0f} mm²")
print(f"最小晶圆直径         : ~{2*math.sqrt((1561/3.75+800)/math.pi):.0f} mm")

print(f"\n结论：90mm 晶圆只能存 ~{ROM_CAP_GB:.0f}GB → 够跑 ≤30B 模型")
print(f"      K3 需要 ~{2*math.sqrt((1561/3.75+800)/math.pi):.0f}mm 以上晶圆（或外挂存储分层）")
