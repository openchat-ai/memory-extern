#!/data/data/com.termux/files/usr/bin/python3
"""eval_arith.py — 加法任务的可验证评估.

不用 CE/ppl 这些间接指标 —— 直接算答案对不对.
输出: 整题正确率 + 逐位数字正确率.
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QXN_GGML", "0")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--vocab", type=int, default=14)
    ap.add_argument("--n", type=int, default=500)
    ap.add_argument("--seed", type=int, default=999, help="与训练数据不同的种子")
    ap.add_argument("--ctx", type=int, default=0, help="前面垫多少道题作上下文")
    a = ap.parse_args()

    from a3_pretrain import compress_vocab
    from qxn_train import build_from_ckpt

    ids = np.load(a.tokens)["ids"].astype(np.int64)
    _, V, _K = compress_vocab(ids, a.vocab)
    cnt = np.bincount(ids)
    cnt[0] = 0
    keep = np.argsort(-cnt)[:V - 1]
    lut = np.zeros(int(ids.max()) + 2, np.int64)
    lut[keep] = np.arange(1, keep.size + 1)
    inv = np.zeros(V, np.int64)
    inv[1:keep.size + 1] = keep

    z = np.load(a.ckpt)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, (L, Dm, F, V, BLK) = build_from_ckpt({k: z[k] for k in z.files}, mode=mode)

    rng = np.random.default_rng(a.seed)
    xs = rng.integers(100, 500, size=a.n)
    ys = rng.integers(100, 500, size=a.n)
    n_ok = n_dig = n_dig_ok = 0
    samples = []
    for i in range(a.n):
        want = str(xs[i] + ys[i])
        pre = ""
        if a.ctx:                      # 前面垫若干道已解出的题, 测上下文鲁棒性
            j = rng.integers(0, i + 1, size=a.ctx)
            pre = "".join(f"{xs[k]}+{ys[k]}={xs[k]+ys[k]}\n" for k in j)
        prompt = f"{pre}{xs[i]}+{ys[i]}="
        x = [lut[c + 1] for c in prompt.encode()]
        got = []
        for _ in range(3):              # 答案恒为 3 位(和 ∈ [200,998])
            lg = np.asarray(m.forward(np.array([x[-48:]], np.int64),
                                     collect=False)[0], np.float64)[-1]
            t = int(lg.argmax())
            if t == 0:
                break
            got.append(chr(int(inv[t]) - 1))
        g = "".join(got)
        ok = (g == want)
        n_ok += ok
        for c1, c2 in zip(g.ljust(3), want):
            n_dig += 1
            n_dig_ok += (c1 == c2)
        if len(samples) < 8:
            samples.append((prompt[-12:], want, g))

    print(f"ckpt={a.ckpt}  mode={mode}  ctx={a.ctx}")
    print(f"  整题正确率 {100*n_ok/a.n:5.1f}%  ({n_ok}/{a.n})")
    print(f"  逐位正确率 {100*n_dig_ok/max(n_dig,1):5.1f}%  ({n_dig_ok}/{n_dig})")
    print("  样例 (提示尾 -> 正确答案 | 模型答案):")
    for p, w, g in samples:
        print(f"    {p:<12} -> {w}  |  {g}")


if __name__ == "__main__":
    main()