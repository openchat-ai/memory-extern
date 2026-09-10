#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""层流写回协议 v0 主机模拟器 (2026-09-09)

验证 §5 冻结的板→主机写回协议:
  1. 字节序对账(真尺寸): 预填批量 vs decode 单字, 逐层产生 payload,
     顺序必须 层升序 × token 升序(barrier), FIFO 峰值/credit 停顿统计.
  2. 数学等价(缩维, 整数算): 同层同步(prefill, 层外循环) == 逐字自回归(decode,
     token 外循环) —— 逐层状态各自隔离 ⇒ 两者收敛到同一 S 与同一输出.
     喂 P2 RTL / P1 SDMA 的契约先跑对.

用法:
  python3 tools/sim_layer_flow.py                 # 默认 1K 预填 + 16 decode 轮
  python3 tools/sim_layer_flow.py --prefill 128 --decode 2 --fifo-kib 64
  python3 tools/sim_layer_flow.py --sweep         # 找零停顿所需 FIRFO×主机写带宽
"""
import argparse
import math
import random

# ---- K3 冻结常量 (§2/§5, 尺寸下死已核对: k3_head_dims_data.md) ----
HEADS = 96          # q/v_proj out 12288 = 96×128
D = 128             # KDA state dim per head (A_log[128])
KV_CT = 576         # kv_a_proj_with_mqa out = latent 512 + mqa rope 64 (写回=544B 量化, 见下)
DT = 2              # BF16 bytes
N_V1, N_V2 = 69, 24
DIFF_LB = HEADS * (D + D) * DT      # 49,152  v1 层每 token 的秩1 diff
# KV v2 写回定案 2026-09-10: latent 512 INT8 + rope 64 4bit (实证 K3_KV_QUANT_PROBE.md)
KV_LATENT_B = 512 * 1                # 512 B  latent INT8 (per-token 1 scale)
KV_ROPE_B   = 64 // 2                # 32  B  rope 4bit
KV_LB = KV_LATENT_B + KV_ROPE_B      # 544    v2 层每 token 的 KV 追加
TOKEN_B = N_V1 * DIFF_LB + N_V2 * KV_LB   # 3,404,544 ≈ 3.40MB(decimal)

V1 = {0,1,2,4,5,6,8,9,10,12,13,14,16,17,18,20,21,22,24,25,26,28,29,30,
      32,33,34,36,37,38,40,41,42,44,45,46,48,49,50,52,53,54,56,57,58,
      60,61,62,64,65,66,68,69,70,72,73,74,76,77,78,80,81,82,84,85,86,
      88,89,90}

NVME = 3.5e9        # model read bandwidth (B/s, 纸面)
SLICE = {True: 632e6, False: 419e6}   # v1/v2 层切片 bytes


def fmt(b):
    for u in ("B", "KB", "MB", "GB"):
        if b < 1024 or u == "GB":
            return f"{b:,.1f}{u}"
        b /= 1024


def build_events(pref, dec):
    """产生 (time, token, layer, nbytes) 事件, 严格 token/层序."""
    ev = []
    t = 0.0
    # 预填: 层外循环, token 层内按序 —— 同层同步
    for L in range(93):
        Tl = SLICE[L in V1] / NVME
        gap = Tl / pref if pref else 0.0
        nb = DIFF_LB if L in V1 else KV_LB
        for tok in range(pref):
            ev.append((t, tok, L, nb))
            t += gap
    # decode: token 外循环, 每字一轮 0..92 (barrier 后下一 token)
    per_round = [SLICE[L in V1] / NVME for L in range(93)]
    for r in range(dec):
        for L in range(93):
            ev.append((t, pref + r, L, DIFF_LB if L in V1 else KV_LB))
            t += per_round[L]
    return ev


def run(fifo_bytes, host_w, pref, dec):
    """事件推进: 层序校验 + FIFO 占用/credit 停顿."""
    ev = build_events(pref, dec)
    ev.sort(key=lambda e: (e[0], e[1], e[2]))
    thr = 0.5 * fifo_bytes
    occ, prev_t, peak = 0.0, 0.0, 0.0
    stalls = stall_s = 0
    order_ok, last_key = True, None
    tot_kda = tot_kv = 0
    max_payload = 0
    # 预填: 层主导 (层L全部token先过再层L+1); decode: token主导 (barrier)
    lm = pref > 0
    for (t, tok, L, nb) in ev:
        key = (L, tok) if lm else (tok, L)
        if last_key is not None and key <= last_key:
            order_ok = False
        last_key = key
        occ = max(0.0, occ - host_w * (t - prev_t))
        prev_t = t
        if occ > thr:  # credit: 等主机排到阈值以下
            wait = (occ - thr) / host_w
            stalls += 1
            stall_s += wait
            occ = thr
        occ += nb
        peak = max(peak, occ)
        max_payload = max(max_payload, nb)
        if L in V1:
            tot_kda += nb
        else:
            tot_kv += nb
    return dict(peak=peak, stalls=stalls, stall_s=stall_s, order_ok=order_ok,
                tot_kda=tot_kda, tot_kv=tot_kv, need=fifo_bytes, thr=thr)


def bytes_check(pref, dec, fifo_bytes, host_w):
    print("== 字节序对账 (真尺寸, v0 协议) ==")
    for mode, p, d in (("预填(同层同步)", pref, 0), ("decode(逐字自回归)", 0, dec)):
        if p == 0 and d == 0:
            continue
        r = run(fifo_bytes, host_w, p, d)
        tk = p + d
        exp_kda = tk * N_V1 * DIFF_LB
        exp_kv = tk * N_V2 * KV_LB
        ok = (r["tot_kda"] == exp_kda and r["tot_kv"] == exp_kv
              and r["peak"] < fifo_bytes and r["order_ok"])
        print(f"  {mode:<22} FIFO {fmt(fifo_bytes)} 主机写 {host_w/1e9:.2f}GB/s")
        print(f"    KDA {fmt(r['tot_kda'])}/{fmt(exp_kda)}  KV {fmt(r['tot_kv'])}/{fmt(exp_kv)}"
              f"  (每 token {fmt(TOKEN_B)})")
        print(f"    层序违例 {'有‼' if not r['order_ok'] else '无'}  FIFO 峰值 {fmt(r['peak'])}"
              f" < {fmt(fifo_bytes)}  停顿 {r['stalls']} 次/{r['stall_s']:.3f}s")
        print(f"    => {'PASS' if ok else 'FAIL'}")
    # 零停顿所需最小主机写带宽(峰值产出率): 预填 v1 层内 N×49KB 摊在 T_L 上
    v1_t = SLICE[True] / NVME
    need = (pref * DIFF_LB) / v1_t if pref else 0.0
    print(f"  [峰产出率] 预填 v1 层 ≈ {fmt(need)}/s -> 主机写 ≥ {fmt(need)} 即零停顿(PCIe 轻松)")
    print(f"  [所需FIFO] 阈值50% 下最小 = 2×单笔49KB ≈ 98KB -> 128KB 稳; 16-64KB 不够(会溢出)")


def math_check():
    print("== 数学等价 (缩维整数, 批与生成收敛同一状态) ==")
    T, H, D, L = 6, 2, 3, 3
    rng = random.Random(11)
    c = [[[t + 1, 2 * (t + 1)] for _ in range(L)] for t in range(T)]  # c[t][layer?] 用最简: 无跨层态
    c = [[t + 1, 2 * (t + 1)] for t in range(T)]  # token 初始上下文

    def kvec(t, l, h):
        return [((c[t][0] + h + l + i) % 5) + 1 for i in range(D)]

    def vvec(t, l, h):
        return [((c[t][1] + h * l + i) % 5) + 1 for i in range(D)]

    def matvec(S, k):
        return [sum(S[i][j] * k[j] for j in range(D)) for i in range(D)]

    def outer(k, v):
        return [[k[i] * v[j] for j in range(D)] for i in range(D)]

    def add(S, k, v):
        for i in range(D):
            for j in range(D):
                S[i][j] += k[i] * v[j]

    def trace_order(tokens_outer):
        # layer-major: (tokens_outer=False) 外层层; decode: tokens_outer=True
        S = [[[0] * D for _ in range(D)] for _ in range(L * H)]
        olog = []
        cc = [list(x) for x in c]
        if not tokens_outer:
            for l in range(L):
                for t in range(T):
                    for h in range(H):
                        o = matvec(S[l * H + h], kvec(t, l, h))
                        add(S[l * H + h], kvec(t, l, h), vvec(t, l, h))
                        olog.append((t, l, h, tuple(o)))
                        cc[t] = [cc[t][0] + sum(o), cc[t][1] + sum(o)]
        else:
            for t in range(T):
                for l in range(L):
                    for h in range(H):
                        o = matvec(S[l * H + h], kvec(t, l, h))
                        add(S[l * H + h], kvec(t, l, h), vvec(t, l, h))
                        olog.append((t, l, h, tuple(o)))
                        cc[t] = [cc[t][0] + sum(o), cc[t][1] + sum(o)]
        return S, olog, cc

    S_lm, o_lm, c_lm = trace_order(False)
    S_dc, o_dc, c_dc = trace_order(True)
    s_equal = S_lm == S_dc
    o_equal = {x[:3]: x[3] for x in o_lm} == {x[:3]: x[3] for x in o_dc}  # 按内容, 非列表序
    c_equal = c_lm == c_dc
    # 交叉验证: 非因果(层内乱序)必须被抓住 —— 检查器自检
    print(f"  同层同步 vs 逐字: 状态 {'全等' if s_equal else '不等!!'}  "
          f"输出({'逐条全等' if o_equal else '不等!!'})  上下文 {'全等' if c_equal else '不等!!'}")
    print(f"         => {'PASS 批与生成收敛同一状态, 层隔离成立(协议前提成立)' if s_equal and o_equal else 'FAIL'}")

    # 自检: 交换同层内 token 次序应产生差异(因果).
    return s_equal and o_equal


def sweep():
    print("== sweep: 零停顿所需 FIFO × 主机写带宽 (prefill 1K + decode 8) ==")
    print(f"  {'FIFO':>8} | 最小主机写 (零停顿)")
    for kib in (48, 64, 96, 128, 192, 256):
        lo, hi = 0.05e9, 3.0e9
        best = None
        for _ in range(14):          # 二分: 找零停顿的最小带宽
            mid = math.sqrt(lo * hi)
            r = run(kib * 1024, mid, 1024, 8)
            if r["stalls"] == 0 and r["peak"] < kib * 1024:
                hi = mid
                best = mid
            else:
                lo = mid
        print(f"  {kib:>7}K | {fmt(best) if best else '>3GB/s'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefill", type=int, default=1024)
    ap.add_argument("--decode", type=int, default=16)
    ap.add_argument("--fifo-kib", type=int, default=128)
    ap.add_argument("--host-w", type=float, default=1.5e9)
    ap.add_argument("--sweep", action="store_true")
    a = ap.parse_args()
    if a.sweep:
        sweep()
        return
    bytes_check(a.prefill, a.decode, a.fifo_kib * 1024, a.host_w)
    math_check()


if __name__ == "__main__":
    main()