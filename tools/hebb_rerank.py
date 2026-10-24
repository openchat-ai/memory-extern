"""hebb_rerank.py — 用 L18 语义方向做候选重排（读出，不改模型）.

与 hebb_steer 的区别:
  steer : 干预  V += α·δ      -> 改变输出分布
  rerank: 读出  score = V·u   -> 只排序, 模型字节与计算图都不变

u = δ_L / |δ_L| (hebb_steer 在情感对比对上构建的方向).
若 δ 真是"情感方向", 那么正向候选在 L18 的 V 投影应更高.

用法:
  python tools/hebb_rerank.py --corr     # 投影 vs 词表极性
  python tools/hebb_rerank.py --demo     # 重排 top-1 对比随机
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_steer import PAIRS, STEMS, Steerer, polarity

LAYER = 18

POS = ["The meal was delicious and the service was excellent.",
       "I loved every minute of this wonderful film.",
       "The hotel room was clean spacious and beautiful.",
       "This is the best purchase I have ever made.",
       "The staff were friendly and incredibly helpful.",
       "The concert was amazing and the crowd was happy.",
       "Her presentation was clear confident and impressive.",
       "The new phone feels fast and the screen is gorgeous.",
       "We had a fantastic time and would happily return.",
       "The book was gripping and the ending was perfect.",
       "The food arrived quickly and tasted great.",
       "Everything worked flawlessly from the very start."]
NEG = ["The meal was cold and the service was awful.",
       "I hated every minute of this boring film.",
       "The hotel room was dirty cramped and ugly.",
       "This is the worst purchase I have ever made.",
       "The staff were rude and completely unhelpful.",
       "The concert was terrible and the crowd was miserable.",
       "Her presentation was confusing nervous and disappointing.",
       "The new phone feels slow and the screen is cracked.",
       "We had a dreadful time and would never return.",
       "The book was dull and the ending was a disaster.",
       "The food arrived late and tasted horrible.",
       "Everything failed badly from the very start."]


class Reader:
    def __init__(self, st):
        self.st = st
        self.E = st.E
        self.d = st.delta[LAYER].reshape(-1).astype(np.float64)
        self.u = self.d / np.linalg.norm(self.d)

    def v(self, text):
        ids = np.array(list(self.E.encode(text)), np.int64)
        (_, _), cap = self.E.forward(ids, capture_kv=True)
        return cap[LAYER][1].reshape(len(ids), -1).astype(np.float64)

    def score_mean(self, text):
        return float((self.v(text) @ self.u).mean() / np.sqrt(self.u.size))

    def score_last(self, text):
        return float(self.v(text)[-1] @ self.u / np.sqrt(self.u.size))


def sample(E, prompt, n_new=18, seed=0, T=1.0):
    rng = np.random.default_rng(seed)
    ids = list(E.encode(prompt))
    lg, cache = E.forward(np.array(ids, np.int64))
    out = []
    for _ in range(n_new):
        z = lg / T
        z = z - z.max()
        p = np.exp(z)
        p /= p.sum()
        t = int(rng.choice(len(p), p=p))
        out.append(t)
        lg, cache = E.forward(np.array([t], np.int64), cache)
    return E.decode_text(out)


def spearman(a, b):
    ra = np.argsort(np.argsort(a))
    rb = np.argsort(np.argsort(b))
    return float(np.corrcoef(ra, rb)[0, 1])


def corr(R):
    print("=== 投影 (V·u) vs 词表极性 ===", flush=True)
    for stem in STEMS[:4]:
        txts = [sample(R.E, stem, seed=s) for s in range(8)]
        pol = [polarity(t)[0] for t in txts]
        sm = [R.score_mean(t) for t in txts]
        sl = [R.score_last(t) for t in txts]
        print(f"  {stem[:24]!r:26s} rho_mean={spearman(sm, pol):+.2f} "
              f"rho_last={spearman(sl, pol):+.2f}  pol范围[{min(pol)},{max(pol)}]",
              flush=True)
    # 汇总: 合并所有 stem
    allp, alls = [], []
    for stem in STEMS:
        for s in range(8):
            t = sample(R.E, stem, seed=s)
            allp.append(polarity(t)[0])
            alls.append(R.score_mean(t))
    print(f"  [合并 n={len(allp)}] rho={spearman(alls, allp):+.2f} "
          f"(非零极性 {sum(p != 0 for p in allp)} 条)", flush=True)
    # 对照: 随机方向
    rng = np.random.default_rng(0)
    keep = R.u
    R.u = rng.normal(0, 1, keep.shape)
    R.u /= np.linalg.norm(R.u)
    alls2 = []
    for stem in STEMS:
        for s in range(8):
            alls2.append(R.score_mean(sample(R.E, stem, seed=s)))
    R.u = keep
    print(f"  [对照 随机方向] rho={spearman(alls2, allp):+.2f}", flush=True)


def auc(pos, neg):
    return float(np.mean([[1.0 if a > b else 0.5 if a == b else 0.0
                           for b in neg] for a in pos]))


def classify(R):
    print("=== 构造句分类 (12 正 / 12 负, 主题互不相同) ===", flush=True)
    for name, f in (("mean", R.score_mean), ("last", R.score_last)):
        p = [f(t) for t in POS]
        n = [f(t) for t in NEG]
        print(f"  {name:5s} AUC={auc(p, n):.3f} "
              f"pos={np.mean(p):+.2f} neg={np.mean(n):+.2f}", flush=True)
    rng = np.random.default_rng(0)
    keep = R.u
    R.u = rng.normal(0, 1, keep.shape)
    R.u /= np.linalg.norm(R.u)
    p = [R.score_mean(t) for t in POS]
    n = [R.score_mean(t) for t in NEG]
    R.u = keep
    print(f"  random AUC={auc(p, n):.3f}", flush=True)


def rank(R):
    print("=== 重排: 每组 4 候选 (2 正 2 负), 取投影最高 ===", flush=True)
    hit = 0
    for i in range(6):
        cands = [(POS[i], 1), (NEG[i], -1),
                 (POS[(i + 3) % 12], 1), (NEG[(i + 7) % 12], -1)]
        scored = sorted(cands, key=lambda c: R.score_mean(c[0]), reverse=True)
        top, lab = scored[0]
        hit += lab == 1
        print(f"  {i}: top={'POS' if lab == 1 else 'NEG'} "
              f"margin={R.score_mean(scored[0][0]) - R.score_mean(scored[-1][0]):+.3f} "
              f"{top[:44]!r}", flush=True)
    print(f"[重排命中 {hit}/6]  随机期望 3/6", flush=True)


def demo(R):
    print("=== 重排: 8 候选取投影最高 vs 随机 ===", flush=True)
    hit = rnd = 0
    for stem in STEMS:
        cands = [(sample(R.E, stem, seed=s), s) for s in range(8)]
        pol = [polarity(t)[0] for t, _ in cands]
        if max(pol) == min(pol):
            continue
        top = max(cands, key=lambda c: R.score_mean(c[0]))
        top_pol = polarity(top[0])[0]
        pick = cands[0][0]
        hit += top_pol == max(pol)
        rnd += polarity(pick)[0] == max(pol)
        print(f"  {stem[:22]!r:24s} 最高极性={max(pol):+d} "
              f"重排选={top_pol:+d} {'OK' if top_pol == max(pol) else ''} | "
              f"{top[0][:44]!r}", flush=True)
    print(f"[重排命中 {hit}]  随机基线 {rnd}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--corr", action="store_true")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--cls", action="store_true")
    ap.add_argument("--rank", action="store_true")
    args = ap.parse_args()
    st = Steerer().build(PAIRS, [LAYER])
    R = Reader(st)
    if args.cls:
        classify(R)
    if args.rank:
        rank(R)
    if args.corr or not (args.demo or args.cls or args.rank):
        corr(R)
    if args.demo:
        demo(R)
    return 0


if __name__ == "__main__":
    sys.exit(main())
