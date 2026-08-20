#!/usr/bin/env python3
"""sim_v1.py — V1 芯片行为模拟器：带宽墙 vs 算力墙，多芯片扩展。

模型（全可复算，与 notes/ 权威口径一致）：
  单芯片 34 MAC @ 1GHz = 34 GMAC/s；LPDDR5X 4ch = 68.3 GB/s；功耗 15.5W。
  GEMV bytes/MAC = 2B（激活复用，只读权重）。
  带宽墙 tok/s  = 带宽 ÷ 模型字节数（decode 受带宽限制）
  算力墙 tok/s  = GMAC/s ÷ 模型参数量（每 token 做 params 次 MAC，与精度无关）
  实际 tok/s    = min(带宽墙, 算力墙) —— int4 只拆带宽墙，MAC 次数不变 → 算力墙锁死
  多芯片 n 颗：带宽 68.3n、MAC 34n、功耗 15.5n（SerDes 线性叠加，理想模型）

用法：python3 sim_v1.py
"""
import sys

GB = 1e9

CHIP = dict(mac=34, bw=68.3, power=15.5, clock=1.0)

MODELS = [
    dict(name="7B",  params=7e9),
    dict(name="13B", params=13e9),
    dict(name="30B", params=30e9),
]

PRECISIONS = [
    dict(name="bf16", bytes_per_param=2.0),
    dict(name="int4", bytes_per_param=0.5),
]

CHIP_COUNTS = [1, 4, 8, 14]


def model_bytes(params, bpp):
    return params * bpp / GB


def bandwidth_wall(bw, params, bpp):
    return bw / model_bytes(params, bpp)


def compute_wall(mac, clock, params):
    return mac * clock / (params / GB)


def main():
    print(f"V1 芯片行为模拟 — 单芯片 {CHIP['mac']} MAC @ {CHIP['clock']}GHz"
          f" / {CHIP['bw']} GB/s / {CHIP['power']}W")
    for model in MODELS:
        for prec in PRECISIONS:
            mb = model_bytes(model["params"], prec["bytes_per_param"])
            bw_w = bandwidth_wall(CHIP["bw"], model["params"], prec["bytes_per_param"])
            c_w = compute_wall(CHIP["mac"], CHIP["clock"], model["params"])
            actual_1 = min(bw_w, c_w)
            print(f"\n{'='*72}")
            print(f"{model['name']} {prec['name']} ({mb:.1f} GB)  — 单芯片: "
                  f"带宽墙 {bw_w:.1f} / 算力墙 {c_w:.1f} → 实际 {actual_1:.1f} tok/s")
            print(f"{'='*72}")
            print(f"{'n颗':>4} {'带宽(GB/s)':>10} {'算力墙':>7} {'带宽墙':>7} "
                  f"{'实际tok/s':>9} {'功耗(W)':>8} {'tok/s/W':>8}")
            for n in CHIP_COUNTS:
                bw = CHIP["bw"] * n
                cw = compute_wall(CHIP["mac"] * n, CHIP["clock"], model["params"])
                bww = bandwidth_wall(bw, model["params"], prec["bytes_per_param"])
                actual = min(bww, cw)
                power = CHIP["power"] * n
                eff = actual / power
                wall = "算力墙" if cw <= bww else "带宽墙"
                print(f"{n:>4} {bw:>10.1f} {cw:>7.1f} {bww:>7.1f} {actual:>9.1f} "
                      f"{power:>8.1f} {eff:>8.2f}   [{wall}]")

    print(f"\n{'='*72}")
    print("结论:")
    print("  1. bf16 下双墙同时到（配平设计）——实际 = 两者相等值")
    print("  2. int4 只拆带宽墙，MAC 次数不变 → 算力墙锁死实际 tok/s（不提速）")
    print("  3. 提速唯一正路 = 加 MAC（多芯片：带宽与 MAC 一起翻倍）")
    print("  4. 对照 RTX 3090: 带宽 936 GB/s / 7B bf16 ~30-40 tok/s / 350W / ~0.1 tok/s/W")
    print(f"     V1 14 颗: 956 GB/s / 68.3 tok/s / 217W / 0.31 tok/s/W (bf16)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
