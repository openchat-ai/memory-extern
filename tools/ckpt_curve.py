#!/data/data/com.termux/files/usr/bin/python3
"""ckpt_curve.py — 对多个 checkpoint 逐个算留出 CE/top1, 画"步数 vs 质量"曲线.

用途: §45 要回答"1-bit 能不能用更少步数追平 fp32", 光看终点不够,
必须逐个 checkpoint 评估, 找出交叉点.
"""
import argparse
import glob
import os
import re
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QXN_GGML", "0")
from a3_pretrain import compress_vocab        # noqa: E402
from qxn_train import build_from_ckpt         # noqa: E402


def eval_ckpt(ck, seq, V, nwin=24, seed=11):
    z = np.load(ck)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, (L, D, F, VV, BLK) = build_from_ckpt({k: z[k] for k in z.files}, mode=mode)
    n = len(seq)
    ho = seq[int(n * 0.95):]
    rng = np.random.default_rng(seed)
    ce, hit = [], []
    for _ in range(nwin):
        s0 = int(rng.integers(0, len(ho) - BLK - 2))
        x = ho[s0:s0 + BLK]
        y = ho[s0 + 1:s0 + BLK + 1]
        lg = np.asarray(m.forward(x[None], collect=True)[0],
                        np.float64).reshape(BLK, VV)
        l = lg - lg.max(-1, keepdims=True)
        l = l - np.log(np.exp(l).sum(-1, keepdims=True))
        kp = y[:BLK - 1] > 0
        ce.append(-l[:BLK - 1][np.arange(BLK - 1), y[:BLK - 1] - 1][kp])
        hit.append((lg.argmax(-1)[:BLK - 1] == y[:BLK - 1])[kp])
    ce, hit = np.concatenate(ce), np.concatenate(hit)
    return float(ce.mean()), float(hit.mean())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--vocab", type=int, required=True)
    ap.add_argument("--glob", action="append", required=True,
                    help="形如 TK_fp32_s*.npz, 重复给多个系列")
    a = ap.parse_args()
    ids = np.load(a.tokens)["ids"]
    seq, V, _ = compress_vocab(ids, a.vocab)
    series = []
    for g in a.glob:
        fs = sorted(glob.glob(g), key=lambda p: int(re.search(r"_s(\d+)", p).group(1))
                    if re.search(r"_s(\d+)", p) else 10 ** 9)
        name = os.path.basename(g).split("_s")[0]
        rows = []
        for f in fs:
            m = re.search(r"_s(\d+)", f)
            step = int(m.group(1)) if m else 10 ** 9
            c, h = eval_ckpt(f, seq, V)
            rows.append((step, c, h))
            print("  %-14s step %6s  CE %.4f  top1 %5.1f%%"
                  % (name, step, c, 100 * h), flush=True)
        series.append((name, rows))
    print()
    for name, rows in series:
        print("%s:" % name, "  ".join("%s:%.2f" % (s, c) for s, c, _ in rows))
    return 0


if __name__ == "__main__":
    sys.exit(main())
