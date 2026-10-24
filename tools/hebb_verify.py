"""hebb_verify.py — 对任意已打包 GGUF 做赫布写入同口径验收 (不修改).

  python tools/hebb_verify.py <file.gguf> [...]
  python tools/hebb_verify.py --facts "k1=v1|k2=v2" <file.gguf>

判据 (docs/HEB_EXPERIMENT.md §10.26):
  事实: 每条 rank 0 (严格) / 值出现在续写里 (语义)
  干扰: 别的值的 token 进了 top3, 或别的值出现在续写里
  holdout: **20 条**提示, **贪心解码**, 与基座逐字比对
    (旧口径 6 条 + 采样 T=0.01 会漏判: 采样噪声底本身 1/20, 见 §10.26.6)
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine, SRC
from hebb_write import HebbWriter

BASE = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
FACTS = [("The largest planet is", "Jupiter"), ("The color of the sky is", "blue")]
HOLD = ["def factorial(n):", "class Point:\n    def __init__", "import os\nos.path.",
        "for i in range(10):", "def quicksort(arr):", "import numpy as np\nnp.",
        "def fib(n):", "while True:", "class A:\n    pass", "with open('f') as f:",
        "try:\n    x = 1\nexcept:", "return [x*2 for x in y]",
        "import json\njson.", "def main():\n    if __name__", "x = {1: 2}",
        "for k, v in d.items():", "assert x == y", "print('hello",
        "def merge(a, b):", "s = 'x' * 3"]


def gen(eng, prompt, n_new=12):
    """贪心解码 (确定性)."""
    ids = list(eng.encode(prompt))
    lg, cache = eng.forward(np.array(ids, np.int64))
    out = []
    for _ in range(n_new):
        t = int(np.argmax(lg))
        out.append(t)
        lg, cache = eng.forward(np.array([t], np.int64), cache)
    return eng.decode_text(out)


def rep_count(text):
    toks = text.split()
    best = cur = 1
    for i in range(1, len(toks)):
        cur = cur + 1 if toks[i] == toks[i - 1] else 1
        best = max(best, cur)
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--facts", default="")
    ap.add_argument("--base", default=BASE)
    args = ap.parse_args()

    facts = FACTS
    if args.facts:
        facts = [tuple(x.split("=", 1)) for x in args.facts.split("|")]

    H = HebbWriter(n_ctx=512)
    E = H.eng
    Ex0 = StreamEngine(slim=args.base, src=SRC, n_ctx=512)
    base_hold = [gen(Ex0, p) for p in HOLD]
    del Ex0

    for path in args.files:
        print(f"\n=== {os.path.basename(path)} ===", flush=True)
        Ex = StreamEngine(slim=path, src=SRC, n_ctx=512)
        vals = [v for _, v in facts]
        tids = [H.target_id(v) for v in vals]
        hit = sem = cross = 0
        for (key, val), tid in zip(facts, tids):
            toks = np.array(Ex.encode(key), np.int64)
            lo, _ = Ex.forward(toks)
            r = int((lo > lo[tid]).sum())
            g = gen(Ex, key, 12)
            ok = r == 0
            hit += ok
            sem += val.lower() in g.lower()
            top3 = set(np.argsort(lo)[::-1][:3].tolist())
            inn = [v for v, t in zip(vals, tids) if t in top3 and v != val]
            wrong = [v for v in vals if v != val and v.lower() in g.lower()]
            cross += bool(inn) or bool(wrong)
            print(f"  {key!r:46s} -> {val!r:12s} rank {r} "
                  f"{'OK' if ok else '   '} {g[:30]!r:32s}"
                  f"{' 串:' + ','.join(inn + wrong) if (inn or wrong) else ''}",
                  flush=True)
        pol = rep_up = 0
        for p, b in zip(HOLD, base_hold):
            g = gen(Ex, p, 12)
            if g != b:
                pol += 1
                rb, rg = rep_count(b), rep_count(g)
                rep_up += rg > rb
                print(f"  [污染] {p!r:26s} rep {rb}->{rg} {b[:30]!r} -> {g[:30]!r}",
                      flush=True)
        print(f"[验收] 事实 {hit}/{len(facts)} rank0 | 含值 {sem}/{len(facts)} | "
              f"串扰 {cross}/{len(facts)} | holdout 污染 {pol}/{len(HOLD)} "
              f"(复读退化 {rep_up})", flush=True)
        del Ex
    return 0


if __name__ == "__main__":
    sys.exit(main())
