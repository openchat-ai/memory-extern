#!/usr/bin/env python3
"""多工艺节点 · 流式 MoE 推理最大输出"""
import math

TR = 25.83  # GB/token

PROCS = [
    ("180nm", 200, 500_000, 3_000),
    ("130nm", 400, 1_500_000, 5_000),
    ("90nm", 600, 5_000_000, 8_000),
    ("55nm", 800, 15_000_000, 15_000),
    ("28nm", 500, 8_000_000, 15_000),
    ("14nm", 1000, 30_000_000, 50_000),
]

NVME_BW = 224  # GB/s

print("=" * 76)
print("流式 MoE 推理 - 多工艺节点最大输出")
print(f"NVMe: {NVME_BW} GB/s | K3 流量: {TR} GB/tok")
print("=" * 76)

print(f"\n{'工艺':<12} {'die':>4} {'MAC/die':>8} {'总MAC':>7} "
      f"{'取指BW':>9} {'K3 tok/s':>8} {'功耗W':>8}")
print("-" * 72)

for pname, fmax_mhz, t_mm2, waf in PROCS:
    freq_ghz = fmax_mhz / 1000.0
    
    best_ts = 0
    best_nd = 4; best_mpd = 64; best_agg = 0; best_pw = 0
    
    for nd in [4, 8, 16, 24, 32]:
        mpd = min(64, max(64, int(80 * 0.15 * t_mm2 / 4000)))
        tm = mpd * nd
        
        fetch = tm * freq_ghz * 0.5   # GB/s: MAC 取指速率
        ops = tm * freq_ghz * 4       # GOPS: int4 SIMD 吞吐
        
        eff_fetch = min(fetch, NVME_BW)
        ts = eff_fetch / TR
        pw = nd * (mpd * 0.294e-3 * fmax_mhz + 8)
        
        if ts > best_ts:
            best_ts = ts; best_nd = nd; best_pw = pw; best_agg = eff_fetch; best_mpd = mpd
    
    k3 = best_agg / TR
    energy = best_pw / k3 if k3 > 0 else 999
    
    print(f"{pname:<12} {best_nd:>4} {best_mpd:>8} {best_mpd*best_nd:>7}"
          f" {best_agg:>9.0f} {k3:>8.1f} {best_pw:>8.0f}")

h200_k3 = 4800 / TR
h200_e = 700 / h200_k3 * 1000
print(f"\nH200x12 : {h200_k3:.0f} t/s | 能效 {h200_energy:.1f} mJ/tok" if False else "")
print(f"H200 x12: 186 t/s/die x 12 = 2232 t/s | ¥420万")
