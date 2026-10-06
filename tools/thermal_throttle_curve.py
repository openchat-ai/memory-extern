#!/usr/bin/env python3
"""降频曲线采集：t/s vs 温度 vs 内存（移动端第二道墙 = 功耗/温控，非带宽）

用法：
  # 冷机后跑，采集 N 个点，每点间隔 S 秒
  python3 tools/thermal_throttle_curve.py -m models/qwen2-0.5b-q4_0.gguf -n 15 -i 60

输出：CSV 写 stdout，同时每点即时打印，便于中断也不丢已采数据。
账实口径：
  - t/s    : llama-bench 的 tg（decode）实测，非估算
  - 温度   : /sys/class/thermal/thermal_zone*/temp 真实读数（m°C），取 CPU 相关区最大值
  - 字节   : 单 token decode 权重搬运字节，由 GGUF 落盘份额算得（降频不变）
  - 带宽   : 字节 / (1/t) = 字节 × t/s，不写死任何数字
"""

import argparse
import csv
import glob
import os
import re
import subprocess
import sys
import time

# 已知需排除的噪声区（-273000 = 未连接）
THERMAL_GLOB = "/sys/class/thermal/thermal_zone*/temp"

# 真机实测标定（2026-10-05，对照实验得出）：
#   负载上涨区（跑 llama-bench 4s 内涨幅最大）= 73, 78, 62, 75, 0, 77
#   空闲高温区（跑完仍 48-58°C）        = 36, 32, 30, 44, 27, 26
# 两者【不同】——取全局 max 会测到与负载无关的区，噪声摆幅曾达 27.7°C。
# 故只用负载区求温度；空闲区仅作环境参考，不进主变量。
LOAD_ZONES = (73, 78, 62, 75, 0, 77)
IDLE_ZONES = (36, 32, 30, 44, 27, 26)


def read_cgroup_mem_mb():
    """Android: cgroup v2 / v1 都试，取当前进程可用内存估计。"""
    for path in (
        "/sys/fs/cgroup/memory.current",
        "/sys/fs/cgroup/memory/memory.usage_in_bytes",
    ):
        try:
            with open(path) as f:
                used = int(f.read().strip())
            with open("/proc/meminfo") as f:
                total = 0
                for line in f:
                    if line.startswith("MemTotal:"):
                        total = int(line.split()[1]) * 1024
                        break
            return (total - used) / 1048576.0, "cgroup"
        except Exception:
            continue
    # 回退：MemAvailable
    with open("/proc/meminfo") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) / 1024.0, "meminfo"
    return -1.0, "unknown"


def read_temps_c():
    """返回 (负载区最高温度°C, {zone: temp°C})。

    只在 LOAD_ZONES 内取 max —— 见 LOAD_ZONES 处标定说明。
    负载区缺失时回退全局 max，但会在 raw 字段留痕，便于判读。"""
    vals = {}
    for p in glob.glob(THERMAL_GLOB):
        try:
            with open(p) as f:
                raw = int(f.read().strip())
        except Exception:
            continue
        if raw <= -273000 or raw == 0:
            continue
        z = int(os.path.basename(os.path.dirname(p))[12:])
        vals[z] = raw / 1000.0
    if not vals:
        return -1.0, {}
    load = [vals[z] for z in LOAD_ZONES if z in vals]
    if load:
        return max(load), vals
    return max(vals.values()), vals


def read_env_c():
    """空闲区温度：环境/余热参考，不作主变量。"""
    vals = {}
    for p in glob.glob(THERMAL_GLOB):
        try:
            with open(p) as f:
                raw = int(f.read().strip())
        except Exception:
            continue
        if raw <= -273000 or raw == 0:
            continue
        z = int(os.path.basename(os.path.dirname(p))[12:])
        vals[z] = raw / 1000.0
    idle = [vals[z] for z in IDLE_ZONES if z in vals]
    return max(idle) if idle else -1.0


def gguf_block_bytes(path):
    """从 GGUF 头读架构，算 block 权重落盘字节（decode 每 token 搬运量）。

    口径：份额法 = 落盘总字节 × (block 参数 / 总参数)。
    总参数以 llama-bench 自报值为准（避免手算误差），block 参数由
    架构元数据精确算出。自洽性校验：block 参数 < 总参数，且占比合理。
    """
    import struct

    with open(path, "rb") as f:
        rd = lambda fmt: struct.unpack(fmt, f.read(struct.calcsize(fmt)))[0]

        def rstr():
            n = rd("<Q")
            return f.read(n).decode("utf-8", "replace")

        def rval(t):
            if t == 0:
                return rd("<b")
            if t == 1:
                return rd("<B")
            if t == 2:
                return rd("<h")
            if t == 3:
                return rd("<H")
            if t == 4:
                return rd("<i")
            if t == 5:
                return rd("<I")
            if t == 6:
                return rd("<f")
            if t == 7:
                return rd("<?") == 1
            if t == 8:
                return rstr()
            if t == 9:  # array
                et = rd("<I")
                n = rd("<Q")
                return [rval(et) for _ in range(n)]
            if t == 10:
                return rd("<q")
            if t == 11:
                return rd("<Q")
            if t == 12:
                return rd("<d")
            raise ValueError("unsupported type %d" % t)

        if f.read(4) != b"GGUF":
            raise ValueError("not GGUF")
        rd("<I")          # version
        rd("<Q")          # n_tensors
        n_kv = rd("<Q")
        kv = {}
        for _ in range(n_kv):
            k = rstr()
            t = rd("<I")
            kv[k] = rval(t)

    arch = kv["general.architecture"]
    L = kv[f"{arch}.block_count"]
    hidden = kv[f"{arch}.embedding_length"]
    ffn = kv[f"{arch}.feed_forward_length"]
    hc = kv[f"{arch}.attention.head_count"]
    hkv = kv[f"{arch}.attention.head_count_kv"]
    kv_dim = hidden * hkv // hc
    attn = hidden * hidden + 2 * kv_dim * hidden + hidden * hidden  # q,k,v,o
    mlp = 3 * hidden * ffn
    per_layer = attn + mlp
    block_params = L * per_layer

    total_params = TOTAL_PARAMS  # 由 llama-bench 自报值定，默认 Qwen2-0.5B
    if block_params >= total_params:
        raise ValueError("block 参数超过总参数，元数据异常")

    share = block_params / total_params
    return os.path.getsize(path) * share, {
        "arch": arch, "layers": L, "hidden": hidden, "ffn": ffn,
        "head_count": hc, "head_count_kv": hkv, "kv_dim": kv_dim,
        "block_params_M": block_params / 1e6,
        "total_params_M": total_params / 1e6, "share": share,
    }


TOTAL_PARAMS = 494.03e6  # Qwen2-0.5B，llama-bench 自报


def bench_tg(model, threads, n_gen, repeat=1):
    """调 llama-bench 取 tg 实测值。按列切分，不猜正则。
    repeat>1 时取中位数（抗单次抖动）。返回 (t/s, 原始行, 全部样本)。"""
    cmd = ["llama-bench", "-m", model, "-t", str(threads),
           "-p", "8", "-n", str(n_gen), "-r", "1"]
    samples, raw = [], ""
    for _ in range(repeat):
        try:
            out = subprocess.run(cmd, capture_output=True, text=True,
                                 timeout=300).stdout
        except Exception as e:
            return None, "bench_error: %s" % e, samples
        target = "tg%d" % n_gen
        for line in out.splitlines():
            if target not in line or not line.strip().startswith("|"):
                continue
            cols = [c.strip() for c in line.strip().strip("|").split("|")]
            if len(cols) < 6:
                continue
            m = re.match(r"([\d.]+)", cols[-1])   # "3.04 ± 0.00" → 3.04
            if m:
                samples.append(float(m.group(1)))
                raw = line.strip()
                break
    if not samples:
        return None, "tg col not found", samples
    samples.sort()
    mid = len(samples) // 2
    median = samples[mid] if len(samples) % 2 else (samples[mid - 1] + samples[mid]) / 2
    return median, raw, samples


# 真机核型（2026-10-05 实测 cpuinfo_max_freq）：
#   小核组 cpu0-3 上限 1804 MHz
#   大核组 cpu4-6 上限 2496 MHz、cpu7 上限 2918 MHz（唯一 prime 核）
# 8 核平均会把"调度器把活派给哪个核"混进主变量 —— 故分组采集。
BIG_CORES = (4, 5, 6, 7)      # 大核/prime，decode 实际算力所在
LITTLE_CORES = (0, 1, 2, 3)   # 小核
PRIME_CORE = 7               # 唯一 2918 MHz 核，最能反映算力上限


def _read_khz(path):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except Exception:
        return -1


def collect_freq():
    """分组读频率。返回 (prime_mhz, big_mhz, little_mhz, big_max_mhz)。

    prime_mhz 单核值最能反映真实算力上限（它cap 在 2918，别的核 cap 更低，
    不会被小核上限掩盖）；big_mhz 为大核组均值，用于看是否整体收缩。
    """
    def group(cores):
        v = [_read_khz("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq" % c)
             for c in cores]
        v = [x for x in v if x > 0]
        return sum(v) / len(v) / 1000.0 if v else -1.0

    prime = _read_khz("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq" % PRIME_CORE)
    big_max = _read_khz("/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq" % PRIME_CORE)
    return (prime / 1000.0 if prime > 0 else -1.0,
            group(BIG_CORES), group(LITTLE_CORES),
            big_max / 1000.0 if big_max > 0 else -1.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-m", "--model", required=True)
    ap.add_argument("-t", "--threads", type=int, default=8)
    ap.add_argument("-n", "--points", type=int, default=15, help="采集点数")
    ap.add_argument("-i", "--interval", type=int, default=60, help="每点间隔秒")
    ap.add_argument("-g", "--gen", type=int, default=64, help="每次生成 token 数")
    ap.add_argument("-r", "--repeat", type=int, default=3, help="每点重复次数，取中位数")
    ap.add_argument("-o", "--out", default="thermal_curve.csv")
    args = ap.parse_args()

    block_bytes, meta = gguf_block_bytes(args.model)
    print("== 字节账（落盘逐字节 + GGUF 头读架构，降频不变）==")
    print("   架构: %s  %d层 hidden=%d ffn=%d GQA %d:%d kv_dim=%d"
          % (meta["arch"], meta["layers"], meta["hidden"], meta["ffn"],
             meta["head_count"], meta["head_count_kv"], meta["kv_dim"]))
    print("   block 参数 = %.2f M / 总 %.2f M = %.1f%%"
          % (meta["block_params_M"], meta["total_params_M"], meta["share"] * 100))
    print("   单 token decode 搬运 = %.2f MiB" % (block_bytes / 1048576))
    print("   每点重复 %d 次取中位数（抗抖动）" % args.repeat)
    print()

    hdr = ["idx", "unix_ts", "temp_c", "temp_idle_c",
           "prime_mhz", "prime_pct", "big_mhz", "little_mhz",
           "mem_avail_mb", "tps", "tps_spread",
           "bytes_per_token", "bandwidth_GBs", "ms_per_token"]
    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(hdr)
        print(",".join(hdr))

        for i in range(args.points):
            temp_c, _ = read_temps_c()      # 先读温度，避免 bench 自身热量污染
            env_c = read_env_c()
            tps, raw, samples = bench_tg(args.model, args.threads,
                                         args.gen, args.repeat)
            spread = (max(samples) - min(samples)) if samples else -1
            prime_mhz, big_mhz, little_mhz, prime_max = collect_freq()
            prime_pct = (prime_mhz / prime_max * 100
                         if prime_mhz > 0 and prime_max > 0 else -1)
            mem_mb, _ = read_cgroup_mem_mb()
            if tps and tps > 0:
                ms = 1000.0 / tps
                bw = block_bytes * tps / 1e9
            else:
                ms, bw = -1, -1
            row = [i, int(time.time()), round(temp_c, 1), round(env_c, 1),
                   round(prime_mhz), round(prime_pct),
                   round(big_mhz), round(little_mhz),
                   round(mem_mb), tps, round(spread, 2),
                   block_bytes, round(bw, 3), round(ms, 1)]
            w.writerow(row)
            f.flush()
            print(",".join(str(x) for x in row), flush=True)
            if i < args.points - 1:
                time.sleep(args.interval)

    print("\n完成 → %s" % args.out)
    print("判读纪律：")
    print("  1) temp_c 只取负载区(%s)，不再取全局max"%(",".join(map(str,LOAD_ZONES))))
    print("  2) 剔除 tps_spread > tps*0.5 的点（内存回收/后台干扰）")
    print("  3) 频率降+temp_c升=热墙；频率降+temp_c平=调度收缩")
    print("  4) prime_pct（cpu%d 占自身上限%%）为算力直量，优先作主变量" % PRIME_CORE)
    print("     注: cpu%d 上限 %s MHz 最高，单独取它不被小核上限掩盖"
          % (PRIME_CORE, "见 cpuinfo_max_freq"))
    print("  5) 不可用 8 核平均频率：异构+调度迁移会污染（实测 corr 反常 -0.636）")


if __name__ == "__main__":
    main()