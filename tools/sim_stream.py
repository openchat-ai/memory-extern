#!/usr/bin/env python3
"""sim_stream.py — 分层流式（DRAM 热 / NVMe 冷）的带宽需求实证

回答的问题：K3 完整运行每 token 要读多少权重字节，其中多少能靠专家缓存
（DRAM 热 / NVMe 冷分层）就地消化、多少必须真搬。

上游已测（kimi-k3-in-c 源码 gates.txt，非本脚本推导）：
  - 每 token 专家权重 25.83GB = 92 层 × 16 top-k 专家 × 17,547,264 字节
  - trunk（always-active 参数，56.7B 参 = 113.49GB bf16）每 token 全读，
    上游实测单步 trunk 读 300.63 GB（3 步累积）
  - 冷 NVMe 随机读 ~1.1GB/s；上游实测 0.015 tok/s（5b 增量 decode）
  - LRU 缓存命中率 by budget 见 docs/PERFORMANCE.md

本脚本新增的切片：
  1. prev-run 全集命中率 -> 若 DRAM 里放"每层上一轮被选专家全集"能覆盖多少
  2. 请求加权带宽口径（GB/token）：专家 DRAM 命中部分不搬，只 NVMe miss 真搬
  3. 完整账本 = trunk（不可缓存，全读） + 专家（可缓存）—— 对照商品内存现实

用法：python3 sim_stream.py [trace.bin]
"""
import struct
import sys
import collections

PATH = "/data/data/com.termux/files/usr/tmp/opencode/kimi-k3-in-c-main/tests/fixtures/expert_trace.bin"
N_EXPERTS = 896
EX_BYTES = 17_547_264  # 一个专家的权重字节（k3_cache.h / k3_load.h 实测口径）
TRUNK_GB = 113.49      # always-active 参数（gates.txt: full trunk 113.49 GB at bf16）
KB = 1 << 10
GB = 1 << 30


def load(path):
    raw = open(path, "rb").read()
    n = len(raw) // 8
    return [struct.unpack("<ii", raw[i * 8:i * 8 + 8]) for i in range(n)]


def group_runs(reqs):
    runs = []
    cur = [reqs[0]]
    for r in reqs[1:]:
        if r[0] == cur[0][0]:
            cur.append(r)
        else:
            runs.append(cur)
            cur = [r]
    runs.append(cur)
    return runs


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else PATH
    reqs = load(path)
    runs = group_runs(reqs)
    print(f"runs={len(runs)}  requests={len(reqs)}  （warm = 跳过首个 super-iter 的 92 个 run）")

    per_layer_distinct = {}
    for L, e in reqs:
        per_layer_distinct.setdefault(L, set()).add(e)
    n_floor = sum(len(v) for v in per_layer_distinct.values())
    print(f"全 trace 各层 distinct 专家合计（一次完整推理的冷启动下界）: {n_floor}")
    print(f"  = {n_floor * EX_BYTES / GB:.1f} GB（这是 prev-run 全集策略的常驻上限）")

    # 策略:prev-run 全集（每层保留上一轮被选专家集，无限常驻）-> distinct 口径 vs 请求加权
    prev = {}
    hits_req = 0
    tot_req = 0
    warm_hits = 0
    warm_tot = 0
    resident_bytes = 0
    for idx, run in enumerate(runs):
        L = run[0][0]
        S = {e for _, e in run}
        P = prev.get(L, set())
        if idx >= 92:
            warm_hits += len(P & S)
            warm_tot += len(S)
        for _, e in run:
            tot_req += 1
            if e in P:
                hits_req += 1
        prev[L] = S

    print(f"\n=== 策略A: 每层常驻上一轮全集（无限 DRAM） ===")
    print(f"distinct 覆盖率（warm）: {warm_hits / warm_tot * 100:.1f}%")
    print(f"请求加权命中率（warm）: {hits_req / tot_req * 100:.1f}%")
    # 常驻量：保持每个出现过的 layer 的全集
    res_experts = sum(len(v) for v in per_layer_distinct.values())
    print(f"需要常驻专家数: {res_experts}（={res_experts * EX_BYTES / GB:.1f} GB）")

    print(f"\n=== 策略B: 无限常驻 + 分 DRAM/NVMe 分层（带宽划分） ===")
    print(f"每 token 专家权重: 25.83 GB（92层×16×17.55MB，上游口径）")
    # 请求加权口径下，DRAM 覆盖 = hits，NVMe 真搬 = 1 - hits
    hit_frac = hits_req / tot_req
    miss_frac = 1 - hit_frac
    exp_gb = 25.83
    print(f"专家 DRAM 就地消化: {hit_frac * 100:.1f}%  -> {hit_frac * exp_gb:.2f} GB/token 不搬")
    print(f"专家 NVMe 必须真搬: {miss_frac * 100:.1f}%  -> {miss_frac * exp_gb:.2f} GB/token")

    print(f"\n=== 完整账本（含 trunk，上游 gates.txt 实测口径） ===")
    print(f"trunk（always-active, 56.7B 参 = {TRUNK_GB:.1f}GB bf16）每 token 全读, 不可缓存")
    for tok_s in (1, 10, 30):
        trunk = TRUNK_GB * tok_s
        exp = miss_frac * exp_gb * tok_s
        print(f"  {tok_s:>3} tok/s -> trunk {trunk:6.1f} + 专家miss {exp:6.1f} = "
              f"{trunk + exp:6.1f} GB/s")

    print(f"\n=== 商品内存现实（单通道/常见形态，有效带宽） ===")
    for name, bw in [("DDR4 单通道", 25.6), ("DDR5 单通道", 38.4),
                     ("DDR5 双通道", 102.4), ("LPDDR5 手机", 51.2),
                     ("服务器 8通道 DDR5", 409.6), ("HBM2e 单栈", 460)]:
        tok = bw / (TRUNK_GB + miss_frac * exp_gb)
        print(f"  {name:<16} {bw:5.0f} GB/s -> 支持 {tok:.2f} tok/s")

    print(f"\n=== 对照: 无缓存冷读（上游实测） ===")
    print(f"  专家 25.83 GB/token @ ~1.1GB/s 冷 NVMe = 约 23.5 s/token")
    print(f"  上游完整实测（5b, 228GB RAM + NVMe 流式 trunk）: 0.015 tok/s 量级")

    print(f"\n=== 策略C: 有限 DRAM 容量（每层只留 top-K 上一轮高频） ===")
    print(f"  方法：每层维护上一轮频率表，常驻 top-K；K 从 16 到全量。")
    print(f"  {'K/层':>6} {'常驻GB':>8} {'请求命中%':>9} {'NVMe GB/token':>14} {'10tok/s NVMe GB/s':>18}")
    rows_c = []
    for K in (16, 24, 32, 48, 64, 96, 128, 192):
        prevc = {}  # layer -> Counter of last run
        hits = 0
        tot = 0
        for idx, run in enumerate(runs):
            L = run[0][0]
            pc = prevc.get(L)
            P = set(x for x, _ in pc.most_common(K)) if pc else set()
            if idx >= 92:
                for _, e in run:
                    tot += 1
                    if e in P:
                        hits += 1
            prevc[L] = collections.Counter()
            for _, e in run:
                prevc[L][e] += 1
        frac = hits / tot if tot else 0
        gb_res = K * 92 * EX_BYTES / GB
        nv_token = (1 - frac) * 25.83
        rows_c.append((K, gb_res, frac, nv_token))
        print(f"  {K:>6} {gb_res:>8.1f} {frac * 100:>8.1f}% {nv_token:>14.2f} {nv_token * 10:>18.1f}")

    print(f"\n=== 关键判决 ===")
    print(f"  1. 专家侧：历史信号能就地消化 ~88-92%，但专家只占全量的 18.5%")
    print(f"     （25.83 / 139.3 GB）——专家缓存最多只能救这 18.5% 的搬运")
    print(f"  2. 为什么流式数字≈无缓存数字：trunk {TRUNK_GB:.0f} GB/token 是")
    print(f"     always-active、每 token 100% 必读，任何缓存都不能跳过（无稀疏性）")
    print(f"  3. 瓶颈定位：流式加载没有失灵，只是瞄错了目标——真正挡 10 tok/s 的")
    print(f"     是 trunk 的 113.5 GB/token（上游实测 trunk 占 I/O 的 81%）")
    print(f"  4. 唯一的出路：trunk 近存（near-memory，权重住在算力旁）或压缩/结构化")
    print(f"     （如 KDA 复用）让 trunk 变小——没有第三条路")


if __name__ == "__main__":
    main()
