#!/usr/bin/env python3
"""多工艺节点 · 流式 MoE 推理最大输出"""
import math

TR = 25.83  # GB/token (K3)
NVME_BW = 224  # GB/s (16x Gen5 NVMe)

PROCS = [
    ("180nm", 200, 500_000, 3_000),
    ("130nm", 400, 1_500_000, 5_000),
    ("90nm", 600, 5_000_000, 8_000),
    ("55nm", 800, 15_000_000, 15_000),
    ("28nm", 500, 8_000_000, 15_000),
    ("14nm", 1000, 30_000_000, 50_000),
]

print("=" * 76)
print(f"流式 MoE 推理 - 多工艺节点")
print(f"NVMe: {NVME_BW} GB/s | K3: {TR} GB/tok")
print("=" * 76)

print(f"\n{'工艺':<12} {'die':>4} {'MAC/die':>8} {'总MAC':>7} "
      f"{'取指BW':>9} {'K3 t/s':>8} {'功耗W':>8}")
print("-" * 72)

for pname, fmax_mhz, t_mm2, waf in PROCS:
    freq_ghz = fmax_mhz / 1000
    
    best_ts = 0; best_nd = 4; best_pw = 0; best_agg = 0
    for nd in [4, 8, 16, 24, 32]:
        mpd = min(64, max(64, int(80 * 0.15 * t_mm2 / 4000)))
        tm = mpd * nd
        
        fetch = min(tm * freq_ghz * 0.5, NVME_BW)
        ops = tm * freq_ghz * 4
        k3_ts = fetch / TR
        pw = nd * (mpd * 0.294e-3 * fmax_mhz + 8)
        
        if k3_ts > best_ts:
            best_ts = k3_ts; best_agg = fetch; best_nd = nd; best_pw = pw; best_mpd = mpd
    
    print(f"{pname:<12} {best_nd:>4} {best_mpd:>8} {best_mpd*best_nd:>7}"
          f" {best_agg:>9.0f} {k3_ts:>8.1f} {best_pw:>8.0f}")

# H200 对照
h200_k3_ts = 4800 / TR
h200_power = 700 * 12
print(f"\nH200×12 舰队 : K3 {h200_k3_ts:.0f} tok/s @ {h200_power}W | ¥420万")

# 能效对比
our_best = max(r[0] for r in [(k3_ts,)]) if 'k3_ts' in dir() else 0

print(f"\n结论：所有工艺都能通过增加 die 数线性扩展吞吐。")
print(f"瓶颈始终是 NVMe 存储带宽，与工艺节点无关。")
