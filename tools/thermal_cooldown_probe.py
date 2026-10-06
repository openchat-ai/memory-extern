#!/usr/bin/env python3
"""静置降温探针：验证"滞后实验"是否可行（不依赖冷机）。

原理：读 /sys/class/thermal 与 scaling_cur_freq 本身几乎不耗算力，
sleep 期间 SoC 可进 idle，故本脚本的观察者效应可忽略。
用它测出"从热态静置，多久降到基准温度"，从而判定能否构造
"同温度、不同热史"的受控对照（hysteresis 实验）。

用法：
  python3 tools/thermal_cooldown_probe.py -n 40 -i 15
  # 40 个点 × 15s = 10 分钟纯静置曲线
"""

import argparse
import csv
import glob
import os
import time


def read_temps():
    vals = {}
    for p in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            with open(p) as f:
                raw = int(f.read().strip())
        except Exception:
            continue
        if raw <= -273000 or raw == 0:
            continue
        vals[os.path.basename(os.path.dirname(p))] = raw / 1000.0
    return vals


def top_temp(vals):
    loaded = [v for v in vals.values() if v >= 30.0]
    return max(loaded) if loaded else (max(vals.values()) if vals else -1.0)


def mean_freq():
    f = []
    for p in glob.glob("/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq"):
        try:
            with open(p) as f2:
                f.append(int(f2.read().strip()) / 1000.0)
        except Exception:
            pass
    return sum(f) / len(f) if f else -1.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-n", "--points", type=int, default=40)
    ap.add_argument("-i", "--interval", type=int, default=15)
    ap.add_argument("-o", "--out", default="results/thermal/cooldown.csv")
    args = ap.parse_args()

    hdr = ["idx", "unix_ts", "elapsed_s", "top_temp_c",
           "mean_cpu_mhz", "n_zones_ge30c"]
    print("== 静置降温探针（纯空闲，无 llama-bench）==")
    print(",".join(hdr))
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(hdr)
        t0 = time.time()
        for i in range(args.points):
            vals = read_temps()
            row = [i, int(time.time()), round(time.time() - t0),
                   round(top_temp(vals), 1), round(mean_freq()),
                   sum(1 for v in vals.values() if v >= 30.0)]
            w.writerow(row)
            f.flush()
            print(",".join(str(x) for x in row), flush=True)
            if i < args.points - 1:
                time.sleep(args.interval)

    print("\n完成 → %s" % args.out)
    print("判读：看 top_temp_c 下降速率（°C/分钟）与 mean_cpu_mhz 是否回落。")


if __name__ == "__main__":
    main()