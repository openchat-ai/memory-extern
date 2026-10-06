#!/usr/bin/env python3
"""绑核对照实验：分离「walt 派活劣化」vs「后台挤占」。

问题（notes/thermal-wall-note.md §5e）：加压后 t/s 降 6.64×、每 token CPU 时间升 6.02×
（等比 ⇒ 纯算力缩放），但机制未定。两个候选：
  (A) walt 调度派活劣化 / 异构迁核开销 —— 若成立，**绑死大核后 t/s 应回稳**
  (B) 后台任务挤占 CPU 时间 —— 若成立，绑核无用，且 cpu_ms/tok 会含后台噪声

设计（每组同一批核型，避免核型混入变量）：
  组1  自由调度   -t 8，不绑       ← 基线
  组2  自由调度   -t 8，不绑       ← 基线重复（测重复性）
  组3  全大核     -t 4，绑 {4,5,6,7}
  组4  全大核     -t 4，绑 {4,5,6,7}
  组5  单大核     -t 1，绑 {4}
  组6  小核       -t 4，绑 {0,1,2,3}   ← 对照：核型上限仅 1804MHz

判读：
  组3/4 t/s 显著高于 组1/2  ⇒ 支持 (A) 派活劣化
  组3/4 与 组1/2 持平       ⇒ 不支持 (A)，转查 (B)
  组5 ≈ 组3/4 ÷ 4           ⇒ 单线程线性，佐证无隐藏并行开销
  组6 远低于 组3/4           ⇒ 核型上限效应（应有 ~0.72× 比值 1804/2496）

关键读量：cpu_ms_per_tok 与 t/s 的比值是否保持等比（§5e 判据）。
绑核后若等比关系破掉，说明此前"纯算力缩放"的结论需修正。
"""

import glob
import os
import re
import statistics
import subprocess
import sys
import time

HZ = os.sysconf("SC_CLK_TCK")
MODEL = os.path.expanduser("~/models/qwen2-0.5b-q4_0.gguf")
LOAD_ZONES = (73, 78, 62, 75, 0, 77)
BYTES_PER_TOK = 255656193.0   # §1 字节账，恒定
GEN = 96


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


def ticks(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            f = f.read().rsplit(")", 1)[1].split()
        return sum(int(f[i]) for i in (11, 12, 13, 14))
    except Exception:
        return None


def run_once(threads, cpus, gen=GEN):
    """绑核（cpus=None 则不绑）跑一次，返回 (tps, cpu_ms_per_tok, wall, tokens)。"""
    cmd = ["llama-bench", "-m", MODEL, "-t", str(threads),
           "-p", "8", "-n", str(gen), "-r", "1"]
    t0 = time.time()
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True,
                         preexec_fn=(lambda: os.sched_setaffinity(0, cpus))
                         if cpus else None)
    c_last, c_sum = ticks(p.pid), 0
    while p.poll() is None:
        c = ticks(p.pid)
        if c is not None and c_last is not None:
            d = c - c_last
            if 0 <= d < 10 * HZ:
                c_sum += d
        if c is not None:
            c_last = c
        time.sleep(0.05)
    out = p.stdout.read()
    wall = time.time() - t0

    tps = None
    for line in out.splitlines():
        if line.strip().startswith("|") and ("tg%d" % gen) in line:
            m = re.match(r"([\d.]+)",
                         line.strip().strip("|").split("|")[-1].strip())
            if m:
                tps = float(m.group(1))
                break
    cpu = c_sum / HZ
    tok = tps * wall if tps else -1
    return tps, (cpu / tok * 1000 if tok > 0 else -1), wall, tok, cpu


def main():
    groups = [
        ("1 自由调度 t8",   8, None),
        ("2 自由调度 t8(重复)", 8, None),
        ("3 全大核 t4",     4, {4, 5, 6, 7}),
        ("4 全大核 t4(重复)", 4, {4, 5, 6, 7}),
        ("5 单大核 t1",     1, {4}),
        ("6 小核组 t4",     4, {0, 1, 2, 3}),
    ]
    print("== 绑核对照实验（每组 -r 1 × %d tok）==" % GEN)
    print("组名                     temp_c   t/s    cpu_s  cpu_ms/tok  带宽GB/s")
    res = []
    for name, th, cpus in groups:
        tc = temp_load()
        tps, mspt, wall, tok, cpu = run_once(th, cpus)
        bw = BYTES_PER_TOK * tps / 1e9 if tps else -1
        res.append((name, tps, mspt))
        print("%-22s %6.1f %6.2f %7.2f %10.1f %9.3f"
              % (name, tc, tps if tps else -1, cpu, mspt, bw), flush=True)
        time.sleep(8)   # 每组间静置，避免连续加压混淆

    print()
    d = dict((n, (t, m)) for n, t, m in res)
    base = [d["1 自由调度 t8"][0], d["2 自由调度 t8(重复)"][0]]
    big = [d["3 全大核 t4"][0], d["4 全大核 t4(重复)"][0]]
    if all(base) and all(big):
        mb, mg = statistics.mean(base), statistics.mean(big)
        print("自由调度 %.2f t/s  vs  全大核 %.2f t/s   → 绑核增益 %+.1f%%"
              % (mb, mg, (mg / mb - 1) * 100))
        print("  → %s" % ("支持『派活劣化』假设(A)" if mg / mb > 1.15 else
                          "不支持(A)：绑核无明显增益，问题在别处"))
    r1 = d["1 自由调度 t8"][1]
    r3 = d["3 全大核 t4"][1]
    if r1 > 0 and r3 > 0:
        print("\ncpu_ms/tok: 自由 %.1f → 全大核 %.1f  (比值 %.2f)"
              % (r1, r3, r3 / r1))
        print("  t/s 比值   %.2f" % ((d['3 全大核 t4'][0] / d['1 自由调度 t8'][0])
                                    if d['1 自由调度 t8'][0] else 0))
        print("  → 两比值%s" % ("接近 ⇒ 等比关系保持，§5e『纯算力缩放』仍成立"
                              if abs(r3 / r1 / (d['3 全大核 t4'][0] / d['1 自由调度 t8'][0]) - 1) < 0.25
                              else "背离 ⇒ §5e 结论需修正"))
    s1, s5 = d["5 单大核 t1"][0], d["3 全大核 t4"][0]
    s6, s3 = d["6 小核组 t4"][0], d["3 全大核 t4"][0]
    if s5 and s3:
        print("\n单大核/全大核 = %.2f  (理想 0.25，若≈0.25 说明线性无隐藏开销)" % (s1 / s3))
    if s6 and s3:
        print("小核组/全大核 = %.2f  (核型上限比 1804/2496 = %.2f)"
              % (s6 / s3, 1804 / 2496))


if __name__ == "__main__":
    main()