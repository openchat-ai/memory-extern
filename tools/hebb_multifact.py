"""hebb_multifact.py — 多事实（不同模板）写入实验.

背景 (docs/HEB_EXPERIMENT.md):
  §10.11.6 已判死"同模板多事实"(只差一个 token 的年份): cos(φ)≈0.98,
  模板共性既是泛化来源也是混淆来源, 不可分离.
  **尚未测的是"不同模板的多条事实"** —— 1L18 只验证过 2 条.

本工具:
  1. --prescreen : 基座知识预筛(必须 base rank>0, 否则写入是空转)
     + 候选 key 之间 φ 两两 cos (模板区分力)
  2. --build      : 写 N 条事实, 两种布局
                   layers : 每条事实一个层 (18,19,20,...)  -> 层间隔离
                   single : 全部事实写同一层              -> 层内求和
  3. 端到端验收: 每条事实 rank 0 + 生成正确 / 交叉污染 / holdout 逐字一致
"""
import argparse
import os
import shutil
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxt_repack as RP
from q1t_stream import StreamEngine, SRC, read_packslim
from hebb_write import HebbWriter

BASE = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
# holdout 扩到 20 条: 6 条时"1 条污染"=17%, 分辨率不够 (§11.4 噪声底)
HOLD = ["def factorial(n):", "class Point:\n    def __init__", "import os\nos.path.",
        "for i in range(10):", "def quicksort(arr):", "import numpy as np\nnp.",
        "def fib(n):", "while True:", "class A:\n    pass", "with open('f') as f:",
        "try:\n    x = 1\nexcept:", "return [x*2 for x in y]",
        "import json\njson.", "def main():\n    if __name__", "x = {1: 2}",
        "for k, v in d.items():", "assert x == y", "print('hello",
        "def merge(a, b):", "s = 'x' * 3"]
HOLD6 = HOLD[:6]

# 候选事实: **模板各不相同**(不是只差一个数字), 答案尽量单 token
CANDS = [
    ("The color of a clear daytime sky is", "blue"),
    ("The chemical symbol for gold is", "Au"),
    ("The capital city of Japan is", "Tokyo"),
    ("The tallest mountain above sea level is", "Everest"),
    ("The first human to walk on the moon was", "Armstrong"),
    ("The programming language created by Guido van Rossum is", "Python"),
    ("The organ that pumps blood through the body is", "heart"),
    ("The gas that makes up most of the Earth's atmosphere is", "nitrogen"),
    ("The metal that is liquid at room temperature is", "mercury"),
    ("The currency used in Switzerland is", "franc"),
    ("The animal that produces milk is", "cow"),
    ("The closest star to Earth is", "Sun"),
    ("The person who wrote the play Hamlet is", "Shakespeare"),
    ("The number of legs that a spider has is", "eight"),
    ("The largest planet in our solar system is", "Jupiter"),
    ("The continent that contains Egypt is", "Africa"),
]


def gen(eng, prompt, n_new=12, temperature=0.01):
    ids, _ = eng.generate(prompt, n_new=n_new, temperature=temperature)
    return eng.decode_text(ids)


def rep_count(text):
    """最长连续重复 token 数 (§10.9 的 rep 判据): 退化复读的量化."""
    toks = text.split()
    best = cur = 1
    for i in range(1, len(toks)):
        cur = cur + 1 if toks[i] == toks[i - 1] else 1
        best = max(best, cur)
    return best


def gen_greedy(eng, prompt, n_new=12):
    """确定性贪心解码: 采样噪声底只有 1/20 (实测), 贪心 = 0."""
    ids = list(eng.encode(prompt))
    lg, cache = eng.forward(np.array(ids, np.int64))
    out = []
    for _ in range(n_new):
        t = int(np.argmax(lg))
        out.append(t)
        lg, cache = eng.forward(np.array([t], np.int64), cache)
    return eng.decode_text(out)


def prescreen(facts, layer=18):
    H = HebbWriter(n_ctx=512)
    E = H.eng
    print("[预筛] base 必须不认得这条 (rank>0), 否则写入是空转", flush=True)
    keep = []
    phis = []
    for key, val in facts:
        toks = np.array(E.encode(key), np.int64)
        lo, _ = E.forward(toks)
        tgt = H.target_id(val)
        r = int((lo > lo[tgt]).sum())
        tk = E.decode_text([tgt])
        phis.append(H.capture_phi(toks)[layer])
        ok = r > 0
        if ok:
            keep.append((key, val))
        print(f"  rank {r:>5}  {tk!r:12s} {key!r:46s} {'KEEP' if ok else 'base 已知'}",
              flush=True)
    P = np.stack(phis)
    nrm = P / np.linalg.norm(P, axis=1, keepdims=True)
    C = nrm @ nrm.T
    iu = np.triu_indices(len(P), 1)
    print(f"[φ 区分力 @L{layer}] 两两 cos: min {C[iu].min():.3f} "
          f"max {C[iu].max():.3f} mean {C[iu].mean():.3f}", flush=True)
    worst = np.argsort(-C[iu])[:5]
    for w in worst:
        a, b = iu[0][w], iu[1][w]
        print(f"    最像的一对: {facts[a][0]!r} <-> {facts[b][0]!r} "
              f"cos={C[a, b]:.3f}", flush=True)
    return keep


def build(facts, layers, c, out, base=BASE, layout="layers", orth=False):
    """orth=True: 每条事实的 phi 对**其它事实的 phi** 做一次 Gram-Schmidt 去共性.

    动机 (§10.11.6 的反面): 同模板去混淆失败是因为模板共性既是泛化来源又是
    混淆来源. 但**多事实场景不需要改写泛化**(每条只用原句问), 所以把共性
    分量正交掉是纯赚: 只保留"这条事实独有"的方向.
    """
    """layout=layers: 第 i 条事实写第 i 层; layout=single: 全部写所有给定层."""
    Ex0 = StreamEngine(slim=base, src=SRC, n_ctx=512)
    base_hold = [gen_greedy(Ex0, p) for p in HOLD]
    del Ex0
    H = HebbWriter(n_ctx=512)
    E = H.eng
    meta, by = read_packslim(base)
    cb = np.asarray(meta["codebook"], np.float32)
    deltas = {i: np.zeros((H.F, H.d), np.float32) for i in layers}
    assign = {}
    CL = list(c) if isinstance(c, (list, tuple)) else [float(c)] * len(facts)
    # 先全部捕获 phi (用于正交化)
    PH = []
    if orth:
        raw = []
        for key, val in facts:
            toks = np.array(E.encode(key), np.int64)
            raw.append(H.capture_phi(toks))
        orthed = {}
        for li in layers:
            M = np.stack([p[li] for p in raw])           # (N, F) 该层所有事实的 phi
            basis = []
            for i in range(len(M)):                      # Gram-Schmidt (顺序相关)
                v = M[i].copy()
                for u in basis:
                    v -= (v @ u) / (u @ u) * u
                n0 = float(np.linalg.norm(M[i]))
                n1 = float(np.linalg.norm(v))
                print(f"  [orth] L{li} fact{i}: |phi| {n0:.1f} -> {n1:.1f} "
                      f"(保留 {n1/max(n0,1e-9):.0%})", flush=True)
                basis.append(v)
                orthed[(i, li)] = v
        PH = [{li: orthed[(i, li)] for li in layers} for i in range(len(raw))]
    for idx, (key, val) in enumerate(facts):
        if layout == "layers":
            ls = [layers[idx % len(layers)]]
        else:
            ls = layers
        assign[key] = ls
        toks = np.array(E.encode(key), np.int64)
        tgt = H.target_id(val)
        phis = PH[idx] if orth else H.capture_phi(toks)
        v = H.embed(tgt)
        ci = CL[idx % len(CL)]
        for i in ls:
            pk = phis[i]
            deltas[i] += np.outer(pk, ci * v) / (pk @ pk)
        print(f"  写 {key!r:46s} -> {val!r:12s} 层 {ls} c={CL[idx % len(CL)]}", flush=True)
    t0 = time.time()
    shutil.copyfile(base, out)
    with open(out, "r+b") as f:
        for i in layers:
            e = by[f"blk.{i}.ffn_down.weight"]
            W = RP.dequant_tensor(base, e, cb)
            f.seek(e["offset"])
            f.write(RP.quant_tensor(W + deltas[i].astype(np.float32), cb))
    print(f"[repack] {len(layers)} 层 {time.time()-t0:.1f}s -> {out}", flush=True)
    return assign


def verify(facts, out, base=BASE):
    """端到端验收: 每条事实 rank 0 / 生成 / 交叉污染 / holdout."""
    Ex0 = StreamEngine(slim=base, src=SRC, n_ctx=512)
    base_hold = [gen_greedy(Ex0, p) for p in HOLD]
    del Ex0
    Ex = StreamEngine(slim=out, src=SRC, n_ctx=512)
    H = HebbWriter(n_ctx=512)
    E = H.eng
    vals = [v for _, v in facts]
    tgt_ids = [H.target_id(v) for v in vals]
    print("[事实] (rank 0 = 正确值排第一; 串 = 别的值进了 top3)", flush=True)
    hit = 0
    sem = 0
    cross = 0
    for (key, val), tid in zip(facts, tgt_ids):
        toks = np.array(Ex.encode(key), np.int64)
        lo, _ = Ex.forward(toks)
        r = int((lo > lo[tid]).sum())
        g = gen(Ex, key, 12)
        others = [v for v in vals if v != val]
        wrong = [v for v in others if v.lower() in g.lower()]
        # 串扰: 别人的值 token 是否进了 top3
        top3 = set(np.argsort(lo)[::-1][:3].tolist())
        inn = [v for v, t in zip(vals, tgt_ids) if t in top3 and v != val]
        ok = r == 0
        hit += ok
        cross += bool(wrong) or bool(inn)
        sem_ok = val.lower() in g.lower()
        sem += sem_ok
        print(f"  {key!r:46s} -> {val!r:12s} rank {r} "
              f"{'OK' if ok else '   '} {'含值' if sem else '不含'} gen {g[:28]!r:30s}"
              f"{'串:' + ','.join(wrong) if wrong else ''}"
              f"{'top3串:' + ','.join(inn) if inn else ''}", flush=True)
    pol = 0
    rep_up = 0
    for p, b in zip(HOLD, base_hold):
        g = gen_greedy(Ex, p, 12)
        if g != b:
            pol += 1
            rb, rg = rep_count(b), rep_count(g)
            if rg > rb:
                rep_up += 1
            print(f"  [污染] {p!r:26s} rep {rb}->{rg}  base {b[:34]!r} -> {g[:34]!r}",
                  flush=True)
    print(f"[验收] 事实 {hit}/{len(facts)} rank0 | 含值 {sem}/{len(facts)} "
          f"| 交叉污染 {cross}/{len(facts)} | holdout 污染 {pol}/{len(HOLD)} "
          f"(其中复读退化 {rep_up})", flush=True)
    return hit, cross, pol
    return hit, cross, pol


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prescreen", action="store_true")
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--verify", default="")
    ap.add_argument("--layout", default="layers", choices=["layers", "single"])
    ap.add_argument("--layers", default="18-22")
    ap.add_argument("--c", type=float, default=20.0)
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--out", default="")
    ap.add_argument("--facts", default="", help="| 分隔的 key=value, 覆盖默认集")
    ap.add_argument("--orth", action="store_true", help="对其它事实的 phi 做 Gram-Schmidt 去共性")
    ap.add_argument("--c-list", default="", help="逗号分隔的每条事实振幅, 覆盖 --c")
    args = ap.parse_args()

    if "-" in args.layers:
        a, b = args.layers.split("-")
        layers = list(range(int(a), int(b) + 1))
    else:
        layers = [int(x) for x in args.layers.split(",")]

    facts = CANDS
    if args.facts:
        facts = [tuple(x.split("=", 1)) for x in args.facts.split("|")]

    if args.prescreen:
        keep = prescreen(facts)
        print(f"[预筛] 保留 {len(keep)}/{len(facts)}", flush=True)
        print("FACTLIST=" + "|".join(f"{k}={v}" for k, v in keep), flush=True)
        return 0

    if args.build:
        facts = facts[:args.n]
        print(f"[build] {len(facts)} 条事实, layout={args.layout}, "
              f"layers={layers}, c={args.c}", flush=True)
        c = args.c
        if args.c_list:
            c = [float(x) for x in args.c_list.split(",")]
        build(facts, layers, c, args.out, layout=args.layout, orth=args.orth)
        verify(facts, args.out)
        return 0

    if args.verify:
        verify(facts, args.verify)
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
