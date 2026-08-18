#!/usr/bin/env python3
"""sim_compare.py — 30B-A3B-2507 真机前对标: 软件缓存 vs 芯片算法

目的: 在你明早于 32GB 无显卡电脑上跑真机前, 先把"软件能达到多少 /
芯片算法能达到多少"的账清楚算出来, 并定义如何用真机实测回填标定。

模型规格 (Qwen3-30B-A3B-Instruct-2507, GGUF Q4_K_M):
  - 总参数 30.5B, 激活 3.3B; 48 层, 每层 128 专家, 每 token 激活 8
  - 每 token 激活 384 专家 ≈ 0.90 GB Q4 (全部 miss 时)
  - trunk (attention/norm/embedding, 不可缓存) ≈ 0.70 GB/token

每 token 搬运 (带宽墙分子):
  A 无缓存   : 0.70 + 0.90                 = 1.60 GB/token
  B 软缓存36%: 0.70 + 0.90×(1-0.36)        = 1.28 GB/token   (llama.cpp 式软件缓存)
  C 芯片 90% : 0.70 + 0.90×(1-0.90)        = 0.79 GB/token   (层优先重排+近存, 已仿真证实上界)

角坠 (min of):
  带宽墙 = bw / 每token搬运
  算力墙: 以真机实测软件基线 T_soft 为锚 —— 软件跑 B 路径, 若 T_soft 远低于
    带宽墙_B, 说明被 CPU 算力/MoE kernel 开销压住; 有效算力墙 F 反推如下,
    芯片连算力一起解则把这层墙去掉, 只留带宽墙。

回填协议 (明早真机):
  Step1: llama-cli -hf unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF:Q4_K_M \\
             -c 8192 -ngl 0 --temp 0.7 --seed 42
         → 实测 token/s = T_soft (默认 16 是 i5 CPU-only 社区量级)
  Step2 (抓真实路由, 鉴定 C 的 90% 是否成立):
         llama.cpp 分支在评分路径 dump 每层 top-8 专家 id →
         "{token} {layer} {e1,e2,...}" → 喂回 sim_cache2/report_real 重算命中率.

用法:
  python3 sim_compare.py                      # 默认软件基线 16 t/s
  T_SOFT=24 python3 sim_compare.py            # 回填真机 Step1
  python3 sim_compare.py --soft 24 --bw 55
"""
import argparse

TRUNK_GB_PT = 0.70
EXPERT_GB_PT = 0.90
BITS_PER_EXPERT_GB = 2.35 / 1024.0            # 每专家 Q4 GB (384×2.35MB≈0.9GB 复核用)

# 社区真机实测 (llama.cpp CPU-only, Q4_K_M, ctx≈8k, TG=token generation)
# 每 token 搬运 ≈ 1.6-1.8 GB (激活 3.3B×~0.5B) → 双通道有效带宽即主瓶颈
CPU_PRESETS = {
    "i5-laptop-ddr4":   dict(soft=8,  bw=26),   # i5-8250U/mobile DDR4
    "desktop-ddr4":     dict(soft=12, bw=32),   # Ryzen 5 5600G / i5-12400
    "ultra-ddr5":       dict(soft=14, bw=34),   # i7-Ultra 155H (mobile DDR5)
    "ryzen7-ddr5":      dict(soft=22, bw=40),   # Ryzen 7 8845HS/8945HS (实测 22-26)
    "xeon4ch-ddr4":     dict(soft=22, bw=52),   # Xeon E5-2680v4 四通道 (实测 22.5)
    "ryzen9-ddr5":      dict(soft=30, bw=60),   # Ryzen 9 7950X (实测 30)
    "ryzen9950-ddr5":   dict(soft=33, bw=65),   # 9950X + DDR5-6400 (~88GB/s 理论, 实测 30+)
}

def bw_tok(hit):
    return TRUNK_GB_PT + EXPERT_GB_PT * (1.0 - hit)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--soft", type=float, default=None,
                    help="真机 Step1 实测软件基线 t/s (默认按 --cpu-model 查预设)")
    ap.add_argument("--cpu-model", default=None,
                    help="预设: " + " / ".join(CPU_PRESETS.keys()))
    ap.add_argument("--bw", type=float, default=None,
                    help="双通道 DDR5 有效读带宽 GB/s (默认按 --cpu-model; 全部省略则 55/16=旧默认)")
    args = ap.parse_args()

    preset = CPU_PRESETS.get(args.cpu_model)
    soft = args.soft if args.soft is not None else (preset["soft"] if preset else 16.0)
    bw = args.bw if args.bw is not None else (preset["bw"] if preset else 55.0)
    if args.cpu_model and preset is None:
        raise SystemExit(f"未知 --cpu-model '{args.cpu_model}'. 可选: {list(CPU_PRESETS)}")
    args.soft, args.bw = soft, bw

    paths = [
        ("A 无缓存(冷读)",     0.00),
        ("B 软件缓存 36%",     0.36),
        ("C 芯片算法  90%",     0.90),
    ]

    bw_walls = {p: args.bw / bw_tok(h) for p, h in paths}
    bw_b = bw_walls["B 软件缓存 36%"]

    # 算力墙反推: 软件在 B 路径上达成 T_soft; 若 T_soft < 带宽墙_B 则被算力压住,
    # 有效算力墙 F 使 B 带宽墙与算力墙竞合后恰为 T_soft (保守取几何平均折中):
    # F = T_soft 当 无带宽空闲假设平坦时; 更稳的边界:
    #   下限 f_lo = min(F, bw_b) = T_soft (带宽未满则算力=T_soft)
    #   若 T_soft >= bw_b 则带宽是主瓶颈, 算力墙 ≥ bw_b.
    if args.soft >= bw_b:
        eff_compute = bw_b          # 带宽先到顶, 算力墙至少这么高
        note = f"软件 ≥ 带宽墙_B({bw_b:.1f}) → 带宽主瓶颈, 算力墙≥{bw_b:.1f} t/s"
    else:
        eff_compute = args.soft     # 未及带宽墙 → 被算力/MoE开销压住
        note = (f"软件 {args.soft:.1f} < 带宽墙_B({bw_b:.1f}) → 算力墙≈{args.soft:.1f} "
                f"t/s (MoE kernel 开销主导)")

    print("=" * 76)
    print("30B-A3B-2507 真机前对标 (Q4_K_M, CPU-only)")
    print(f"输入: 软件基线 {args.soft:.1f} t/s · 带宽 {args.bw:.0f} GB/s")
    print(f"每 token 搬运: trunk {TRUNK_GB_PT}B + 激活专家 {EXPERT_GB_PT}B(Q4, 可缓存)")
    print(f"带宽墙: A {bw_walls['A 无缓存(冷读)']:.1f} · "
          f"B {bw_b:.1f} · C {bw_walls['C 芯片算法  90%']:.1f} t/s")
    print(f"算力墙反推: {note}")
    print("-" * 76)
    print("┌──────────────┬──────────┬──────────┬──────────┐")
    print("│ 路径          │ 带宽墙   │ 算力墙   │ 现实可达 │")
    print("├──────────────┼──────────┼──────────┼──────────┤")
    for p, _ in paths:
        w = bw_walls[p]
        # 芯片(已解带宽)只受算力墙; 软件路径 (A/B) 受双墙竞合
        if p == "C 芯片算法  90%":
            reach = min(w, eff_compute * 1.0)
        else:
            reach = min(w, eff_compute)
        print(f"│ {p:<12} │ {w:>8.1f} │ {eff_compute:>8.1f} │ {reach:>8.1f} │")
    print("└──────────────┴──────────┴──────────┴──────────┘")
    print()

    # 转译: 芯片是否存在增量
    reach_b = min(bw_walls["B 软件缓存 36%"], eff_compute)
    reach_c = min(bw_walls["C 芯片算法  90%"], eff_compute)
    print(f"结论: 软件基线 ≈ {args.soft:.1f} t/s.")
    print(f"  若算力墙 ≈ {eff_compute:.1f} (语义: B 已到算力墙):")
    print(f"    C 与 B 同为 {reach_c:.1f} vs {reach_b:.1f} → 芯片纯缓存增量 "
          f"{max(reach_c - reach_b, 0):.1f} t/s (仅当算力墙不随之抬高).")
    print(f"  若芯片连算力一起解 (卸载专家 GEMM, 算力墙 → 无限):")
    print(f"    C 可达带宽墙 {bw_walls['C 芯片算法  90%']:.1f} t/s — 但要碰到 50 线, 带宽或命中")
    print(f"    仍需继续加码 (90% 命中需真机 trace 才成立, 不能拿合成 trace 当数).")
    print()
    print("明天真机三件事:")
    print("  1. T_SOFT 实测 → 决定算力墙在哪 (本脚本 --soft 回填).")
    print("  2. 若 T_SOFT ≥ 30: 带宽主瓶颈成立, 芯片缓存故事完全成立.")
    print("  3. 抓真实路由 trace → 用 sim_cache2/report_real 换 90% 真假.")

if __name__ == "__main__":
    main()