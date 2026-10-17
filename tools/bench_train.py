"""训练速度基准 + roofline 分析.

目的: 为"训练加速"研究建立可复现的基线. 每个配置输出
  - 实测 fwd / bwd / tok/s
  - FLOPs 口径的 MFU (Model FLOPs Utilization)
  - 字节口径的算术强度, 与实测 3.6 GB/s 内存带宽对比
  - 到目标模型规模的可达性外推

用法:
  python3 tools/bench_train.py                 # 跑全部基准配置
  python3 tools/bench_train.py --quick         # 只跑快速档
  python3 tools/bench_train.py --roofline      # 只算 roofline 表
"""
import argparse
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxn_train as Q  # noqa: E402

# ---- 本机实测常数 ----
# CPU 拓扑: cpu0-3 = 1.80GHz (小核), cpu4-6 = 2.50GHz (大核), cpu7 = 2.92GHz (超大核)
# 实测: 绑 cpu7 单线程 sgemm 48.8~52.4 GFLOPS; 任何含 cpu4-6 的多线程配置
#       只有 27.7 GFLOPS. 训练端到端: cpu7 单线程 223.1 tok/s vs 全核 156.9 tok/s
#       => 绑超大核单线程比用满 8 核快 1.42x. 手机 SoC 上多线程是净损失.
GEMM_PEAK = 49.0e9      # OpenBLAS sgemm 峰值 (taskset -c 7, 单线程)
GEMM_PEAK_ALL = 33.3e9  # 不绑核 / 多线程时的峰值
MEM_BW = 3.6e9          # memcpy 实测带宽


def train_flops(n_param, n_tok):
    """前向+反向的标准 FLOPs 口径: 6ND (2N 前向, 4N 反向)."""
    return 6.0 * n_param * n_tok


def bench_one(n_layer, n_embd, n_ff, vocab, mode, bs, seq, reps=3,
              collect=True):
    """亲和性由外部 taskset 决定 (见 --affinity)."""
    tok = np.random.randint(0, vocab, (bs, seq))
    m = Q.QxN(n_layer, n_embd, 4, n_ff, vocab, seq,
              mode=mode, seed=0)
    n_param = sum(v.size for v in m.P.values())
    m.forward(tok, collect=False)          # 预热
    ts = []
    for _ in range(reps):
        t = time.time()
        lg, c, xf, xl, oc = m.forward(tok, collect=collect)
        tf = time.time() - t
        t = time.time()
        m.backward(tok, lg, c, xf, xl, oc)
        tb = time.time() - t
        ts.append((tf, tb))
    tf = min(a for a, _ in ts)
    tb = min(b for _, b in ts)
    n_tok = bs * seq
    tps = n_tok / (tf + tb)
    flops = train_flops(n_param, n_tok)
    mfu = flops / (tf + tb) / GEMM_PEAK
    # 权重流量: 前向读 1 次, 反向读 2 次 (dgrad + wgrad)
    wbytes = 3.0 * n_param * 4.0
    intensity = flops / wbytes
    return dict(n_layer=n_layer, n_embd=n_embd, vocab=vocab, mode=mode,
                bs=bs, seq=seq, n_param=n_param,
                fwd=tf, bwd=tb, tok_per_s=tps, mfu=mfu,
                bwd_over_fwd=tb / tf,
                ai_flops_per_byte=intensity,
                mem_bound_us=1e6 * wbytes / MEM_BW)


CONFIGS = [
    # (label, n_layer, n_embd, n_ff, vocab, mode, bs, seq)
    ("micro  L2d64  V8k",    2,   64,  128,   8192, "bitnet", 4, 64),
    ("bench  L4d192 V32k",   4,  192,  384,  32768, "bitnet", 4, 64),
    ("bench  L4d192 V32k",   4,  192,  384,  32768, "fp32",   4, 64),
    ("target L8d512 V32k",   8,  512, 1024,  32768, "bitnet", 4, 64),
    ("target L8d512 V151k",  8,  512, 1024, 151936, "bitnet", 4, 64),
]


def roofline_table():
    """不同规模 + 不同 token 量下, 按实测算力需要多久."""
    eff = GEMM_PEAK * 0.5          # 按 50% MFU 估计
    print("\n%-32s %10s %10s %14s" % ("目标 (参数量/语料)", "tok/s", "现状", "300x"))
    print("-" * 70)
    out = []
    for name, N, tok in [("14M / 25万 token",   14e6,   2.5e5),
                         ("50M / 5亿 token",     50e6,   5e8),
                         ("50M / 10亿 token",    50e6,   1e9),
                         ("100M / 10亿 token",  100e6,   1e9),
                         ("600M / 200亿 token",  0.6e9,  20e9)]:
        tps = eff / (6.0 * N)
        base = tok / tps

        def fmt(s):
            if s < 60:
                return "%.0f 秒" % s
            if s < 3600:
                return "%.0f 分钟" % (s / 60)
            if s < 86400:
                return "%.1f 小时" % (s / 3600)
            if s < 86400 * 365:
                return "%.0f 天" % (s / 86400)
            return "%.1f 年" % (s / 86400 / 365)
        print("%-32s %10.2f %10s %14s" % (name, tps, fmt(base), fmt(base / 300)))
        out.append(dict(name=name, n=N, tokens=tok, tok_per_s=tps,
                        base_sec=base))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quick", action="store_true")
    ap.add_argument("--roofline", action="store_true")
    ap.add_argument("--out", default="bench_train.json")
    ap.add_argument("--affinity", default="7",
                    help="CPU 亲和性 (7=超大核单线程, 已实测最优)")
    ap.add_argument("--reexec", action="store_true", default=True,
                    help="用 taskset 重新执行自身以应用亲和性")
    args = ap.parse_args()

    if args.reexec and not os.environ.get("_BENCH_AFFINITY"):
        os.environ["_BENCH_AFFINITY"] = "1"
        os.execvp("taskset",
                  ["taskset", "-c", args.affinity, sys.executable] +
                  [os.path.abspath(__file__)] + sys.argv[1:])

    print("[亲和性] taskset -c %s, OPENBLAS_NUM_THREADS=%s"
          % (args.affinity, os.environ.get("OPENBLAS_NUM_THREADS", "1")))
    if not args.roofline:
        print("=" * 78)
        print("训练速度基准 (aarch64, 8核, 实测 sgemm 峰值 %.1f GFLOPS, "
              "内存带宽 %.1f GB/s)" % (GEMM_PEAK / 1e9, MEM_BW / 1e9))
        print("=" * 78)
        print("%-20s %7s %8s %8s %9s %7s %9s" %
              ("配置", "参数", "fwd", "bwd", "tok/s", "MFU", "bwd/fwd"))
        print("-" * 78)
        rows = []
        for label, *cfg in (CONFIGS[1:3] if args.quick else CONFIGS):
            r = bench_one(*cfg)
            r["label"] = label
            rows.append(r)
            print("%-20s %6.1fM %7.2fs %7.2fs %9.1f %6.1f%% %9.2f" %
                  (r["label"],
                   r["n_param"] / 1e6, r["fwd"], r["bwd"], r["tok_per_s"],
                   r["mfu"] * 100, r["bwd_over_fwd"]))
        print()
        print("%-20s %12s %14s %s" % ("配置", "算术强度", "权重搬运耗时",
                                      "判定"))
        print("-" * 78)
        for r in rows:
            mem_ms = r["mem_bound_us"] / 1000
            tot = (r["fwd"] + r["bwd"]) * 1000
            verdict = "内存墙" if mem_ms > tot else "算力墙"
            print("%-20s %9.1f F/B %11.0f ms %6.0f ms  %s" %
                  (r["label"],
                   r["ai_flops_per_byte"], mem_ms, tot, verdict))
        with open(args.out, "w") as f:
            json.dump(rows, f, indent=2)
        print("\n[已写入 %s]" % args.out)

    roofline_table()


if __name__ == "__main__":
    main()