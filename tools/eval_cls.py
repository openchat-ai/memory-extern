#!/data/data/com.termux/files/usr/bin/python3
"""eval_cls.py — 代码行分类的准确率评估(留出集, jsonl 尾部未参与训练).

窗口以 "@" 结尾, 取该位置 argmax 的下一个字节作为预测标签.
同时报告"永远猜最高频类"的基线, 避免被基线误导.
"""
import argparse
import json
import os
import sys
from collections import Counter

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QXN_GGML", "0")
from mk_cls_data import LABELS, label_of          # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--vocab", type=int, default=200)
    ap.add_argument("--n", type=int, default=400)
    ap.add_argument("--ctx", type=int, default=6)
    ap.add_argument("--win", type=int, default=0, help="0=用 checkpoint 的 posembd 行数")
    ap.add_argument("--jsonl", default="/data/data/com.termux/files/home/sram/"
                    "magicoder_a3.jsonl")
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
    # 只有训练里当过标签的字符才算候选
    lab_bytes = {c: lut[ord(c) + 1] for c in LABELS}

    z = np.load(a.ckpt)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, (L, Dm, F, V, BLK) = build_from_ckpt({k: z[k] for k in z.files}, mode=mode)

    # 留出集: 从 jsonl 末尾取文档(生成器从头部开始取, 尾部未参与训练)
    docs = []
    with open(a.jsonl, encoding="utf-8") as f:
        for line in f:
            docs.append(line)
    rng = np.random.default_rng(4242)
    order = rng.permutation(len(docs))[-1200:]
    items = []
    for di in order:
        ls = json.loads(docs[di])["code"].split("\n")
        for i in range(a.ctx, len(ls)):
            if ls[i].strip():
                items.append((ls, i))
            if len(items) >= a.n:
                break
        if len(items) >= a.n:
            break

    ok = 0
    cm = Counter()
    for ls, i in items[:a.n]:
        cur = ls[i]
        want = label_of(cur)
        ctx = "\n".join(ls[i - a.ctx:i])
        if len(ctx) > 700:
            ctx = ctx[-700:]
        w = f"{ctx}\n@@{cur}\n@"
        if len(w) > (a.win or BLK):
            w = w[-780:]
        x = [lut[c + 1] for c in w.encode()]
        lg = np.asarray(m.forward(np.array([x[-(a.win or BLK):]], np.int64),
                                 collect=False)[0], np.float64)[-1]
        # 只在标签字符里选, 排除模型输出别的字节
        cand = {c: float(lg[lab_bytes[c]]) for c in LABELS if lab_bytes[c] != 0}
        pred = max(cand, key=cand.get) if cand else "?"
        ok += (pred == want)
        cm[(want, pred)] += 1

    n = min(a.n, len(items))
    base = Counter(label_of(l[i]) for l, i in items[:n])
    top = base.most_common(1)[0]
    print(f"ckpt={a.ckpt}  mode={mode}  n={n}")
    print(f"  准确率     {100*ok/n:5.1f}%   ({ok}/{n})")
    print(f"  基线(永远猜 {top[0]}) {100*top[1]/n:5.1f}%")
    print("  真实分布: " + "  ".join(f"{k} {100*v/n:.0f}%" for k, v in
                                     sorted(base.items())))
    print("  混淆(真实->预测, 只列 top6):")
    for (w, p), c in cm.most_common(6):
        print(f"    {w} -> {p}   {c:3d} 次 ({100*c/n:.1f}%)")


if __name__ == "__main__":
    main()