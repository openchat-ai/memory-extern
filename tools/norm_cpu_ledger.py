#!/usr/bin/env python3
"""归一化 CPU 账：CPU 秒 / token —— 不依赖频率的算力直量。

背景（见 notes/thermal-wall-note.md §5c）：walt 调度器在异构核间迁移任务，
`scaling_cur_freq` 反映派活策略而非热收缩（实测 big_mhz 与 t/s 反常 -0.843），
故频率无法作主变量。本脚本改用**进程 CPU 时间**：
读 /proc/<pid>/stat 的 utime+stime+cutime+cstime（子进程含 llama-bench 全部 8 线程）。

优势：CPU 秒/token 是**归一化**的量 —— 若 t/s 下降源于"算力被压"，
则 CPU 秒/token 应上升（每 token 需更多 CPU 时间补偿降频）；
若 t/s 下降源于"纯等待/内存"，CPU 秒/token 应不变。这是频率给不出的判别力。

注意：/proc/stat 与 policy*/stats 在 Termux 沙箱内 Permission denied，
仅 /proc/<pid>/stat 可读，故只能测本进程子树（对本实验已足够）。
"""

import csv
import glob
import os
import re
import subprocess
import sys
import time

HZ = os.sysconf("SC_CLK_TCK")
LOAD_ZONES = (73, 78, 62, 75, 0, 77)
MODEL = os.environ.get("BENCH_MODEL", os.path.expanduser("~/models/qwen2-0.5b-q4_0.gguf"))


def child_ticks(pid):
    """utime+stime+cutime+cstime（字段 14-17，1-based；rsplit 处理 comm 内的空格/括号）。"""
    try:
        with open("/proc/%d/stat" % pid) as f:
            f = f.read().rsplit(")", 1)[1].split()
        return sum(int(f[i]) for i in (11, 12, 13, 14))
    except Exception:
        return None


def temp_load():
    v = {}
    for p in glob.glob("/sys/class/thermal/thermal_zone*/temp"):
        try:
            r = int(open(p).read().strip())
        except Exception:
            continue
        if r <= -273000 or r == 0:
            continue
        v[int(os.path.basename(os.path.dirname(p))[12:])] = r / 1000
    l = [v[z] for z in LOAD_ZONES if z in v]
    return max(l) if l else -1.0


BIG_CORES = (4, 5, 6, 7)   # 实测上限 2496MHz，§5f 绑核组
LITTLE_CORES = (0, 1, 2, 3)  # 实测上限 1804MHz


def parse_cpus(spec):
    """'big' | 'little' | 'all' | '4,5,6' -> 核集合或 None(None=不绑)。"""
    if spec in (None, "", "none", "free"):
        return None
    if spec == "big":
        return set(BIG_CORES)
    if spec == "little":
        return set(LITTLE_CORES)
    if spec == "all":
        return None
    return {int(x) for x in spec.split(",") if x.strip()}


def bench_once(gen, threads=8, cpus=None):
    """跑一次 llama-bench，返回 (tps, cpu_s, wall_s, tokens)。

    cpus 非 None 时绑核 —— §5f：绑大核比自由调度快 5.70×，
    故所有跨组比较必须声明绑核方式。"""
    cmd = ["llama-bench", "-m", MODEL, "-t", str(threads),
           "-p", "8", "-n", str(gen), "-r", "1"]
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True,
                         preexec_fn=(lambda: os.sched_setaffinity(0, cpus))
                         if cpus else None)
    # 边跑边轮询累积：子进程可能在 communicate() 前就退出，
    # 只读起止两点会拿到 None（首版实测 cpu_s=-1 即此因）。
    c0 = child_ticks(p.pid)
    c_last, c_sum = c0, 0
    c_prev, peak_rss = c0, 0
    while p.poll() is None:
        c = child_ticks(p.pid)
        if c is not None:
            if c_last is not None:
                d = c - c_last
                if 0 <= d < 10 * HZ:      # 忽略异常跳变
                    c_sum += d
            c_last = c
        try:
            with open("/proc/%d/status" % p.pid) as f:
                for line in f:
                    if line.startswith("VmHWM:"):
                        peak_rss = max(peak_rss, int(line.split()[1]))
                        break
        except Exception:
            pass
        time.sleep(0.05)
    out = p.stdout.read()
    wall = time.time() - t0
    cpu = c_sum / HZ if c_sum > 0 else -1.0
    del peak_rss
    for line in out.splitlines():
        if line.strip().startswith("|") and ("tg%d" % gen) in line:
            m = re.match(r"([\d.]+)",
                         line.strip().strip("|").split("|")[-1].strip())
            if m:
                tps = float(m.group(1))
                break
    # 该次运行生成 token 数 ≈ tps × wall（含 prompt 阶段，取近似）
    tokens = tps * wall if tps else -1
    return tps, cpu, wall, tokens


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 6
    gen = int(sys.argv[2]) if len(sys.argv) > 2 else 48
    gap = int(sys.argv[3]) if len(sys.argv) > 3 else 5
    pin = sys.argv[4] if len(sys.argv) > 4 else "big"   # 默认绑大核（§5f 最优）
    out = sys.argv[5] if len(sys.argv) > 5 else "results/thermal/norm_cpu.csv"
    cpus = parse_cpus(pin)

    hdr = ["idx", "temp_c", "tps", "cpu_s", "wall_s", "tokens",
           "cpu_ms_per_tok", "bandwidth_GBs", "pin"]
    print("== 归一化 CPU 账（%d 点 × %d tok，间隔 %ds，绑核=%s）=="
          % (n, gen, gap, pin))
    print("绑核集合: %s" % (sorted(cpus) if cpus else "不绑（自由调度）"))
    print(",".join(hdr))
    rows = []
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(hdr)
        for i in range(n):
            tc = temp_load()
            tps, cpu, wall, tok = bench_once(gen, threads=len(cpus) if cpus else 8,
                                              cpus=cpus)
            if tps and cpu > 0 and tok > 0:
                mspt = cpu / tok * 1000
                bw = float(os.environ.get("BENCH_BYTES", "255656193.0")) * tps / 1e9
            else:
                mspt = bw = -1
            row = [i, round(tc, 1), tps, round(cpu, 2), round(wall, 2),
                   round(tok) if tok > 0 else -1, round(mspt, 2), round(bw, 3), pin]
            w.writerow(row)
            f.flush()
            rows.append(row)
            print(",".join(str(x) for x in row), flush=True)
            if i < n - 1:
                time.sleep(gap)

    print("\n完成 → %s" % out)
    print("判读（仅同一 pin 内可比，§5f.3 跨组等比关系不成立）：")
    print("      t/s 降 而 cpu_ms_per_tok 升 ⇒ 算力被压")
    print("      t/s 降 而 cpu_ms_per_tok 平 ⇒ 非算力问题（内存/等待）")


if __name__ == "__main__":
    main()