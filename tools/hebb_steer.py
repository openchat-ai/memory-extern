"""hebb_steer.py — V 通道对比写入（行为引导，零训练）.

依据 docs/HEB_EXPERIMENT.md §10.18.2（Knowledge Packs）:
  RoPE 只旋转 K, 不动 V -> V 是"无位置"的语义通道.
  同一句骨架、只改情感词的对比对, 其 V 之差是一个可加的方向.

机制:
  δ_L = mean(V_L[pos=-1] | 正面句) − mean(V_L[pos=-1] | 负面句)
  生成时在每个新位置的 V 上加 α·δ_L（预填只加在最后一个位置）

实测 (§10.20, 层扫描 8~22):
  层 18 (64% 深度) 是两条通路的共同写入点:
    情感 δ:  logit(good)-logit(bad)   +0.22 -> +3.29  (α -4 -> +4)
    语言 δ:  logit( le )-logit( the ) -8.10 -> -3.57
  其它层 ~0; 随机 δ ~0; 异属性 δ 不迁移; cos(情感,语言)=0.012 (可叠加)
  自由生成层**未观测到**连贯切换 (α>=6 崩坏) -> 这是 logit 级旋钮, 不是行为层.

边界 (docs/HEB_EXPERIMENT.md §10.25):
  **不能烘进 GGUF** —— V 常数偏移等价于注意力输出偏置, 而 Q4T 格式
  196 张量 0 bias, 没有 bias 就没有位置放. 这是**运行时**能力.

用法:
  python tools/hebb_steer.py --scan      # 层 x α 扫描 (生成极性, 判据弱)
  python tools/hebb_steer.py --probe     # 确定性 logit 探针 (推荐)
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_write import HebbWriter

POS = """good great excellent wonderful fantastic best love happy beautiful
success amazing perfect enjoy delightful brilliant positive superior
impressive pleasure favorite flawless""".split()
NEG = """bad terrible awful worst hate sad miserable failure disaster horrible
poor disappointing wrong negative inferior dull boring useless
tragic flaw annoying""".split()
LEX = {w: 1 for w in POS}
LEX.update({w: -1 for w in NEG})

PAIRS = [
    ("The film was absolutely wonderful and I", "The film was absolutely terrible and I"),
    ("I really love this book, it is", "I really hate this book, it is"),
    ("The service was excellent and the food was", "The service was awful and the food was"),
    ("This is a fantastic idea, I", "This is a horrible idea, I"),
    ("The result was a great success and", "The result was a total disaster and"),
    ("We are very happy with the outcome because", "We are very disappointed with the outcome because"),
    ("The weather was beautiful and", "The weather was miserable and"),
    ("The movie made me feel joyful and", "The movie made me feel sad and"),
]

STEMS = [
    "The film was",
    "I thought the book was",
    "The weather today is",
    "Overall, this product is",
]

LAYERS = [8, 10, 12, 14, 16, 18, 20, 22]

HELD = ["The meal was", "The hotel room was", "His performance was",
        "The ending of the story was", "The new phone is", "Her presentation was"]

PROBE = [("good / bad", (" good", " bad")),
         ("positive / negative", (" positive", " negative")),
         ("the / a", (" the", " a")),
         ("cat / dog", (" cat", " dog")),
         ("blue / red", (" blue", " red"))]


def polarity(text):
    toks = [t.strip(".,!?;:\"'()").lower() for t in text.split()]
    s = sum(LEX.get(t, 0) for t in toks)
    n = sum(1 for t in toks if t in LEX)
    return s, n


class Steerer:
    def __init__(self):
        self.H = HebbWriter()
        self.E = self.H.eng
        self.delta = {}

    def capture_last(self, text, layers):
        ids = np.array(list(self.E.encode(text)), np.int64)
        (_, _), cap = self.E.forward(ids, capture_kv=True)
        return {L: cap[L][1][-1].copy() for L in layers}

    def build(self, pairs, layers):
        for L in layers:
            acc = np.zeros((self.E.n_kv, self.E.hd), np.float32)
            for p, n in pairs:
                acc += self.capture_last(p, [L])[L] - self.capture_last(n, [L])[L]
            self.delta[L] = acc / len(pairs)
        return self

    def gen(self, prompt, layers, alpha, n_new=20):
        vd = {L: ([-1], alpha * self.delta[L]) for L in layers}
        ids = list(self.E.encode(prompt))
        lg, cache = self.E.forward(np.array(ids, np.int64), v_delta=vd)
        out = []
        for _ in range(n_new):
            t = int(np.argmax(lg))
            out.append(t)
            vd1 = {L: (None, alpha * self.delta[L]) for L in layers}
            lg, cache = self.E.forward(np.array([t], np.int64), cache, v_delta=vd1)
        return self.E.decode_text(out)


def scan(st, layers, alphas, stems):
    print(f"{'layer':>5} {'|d|':>6} " + " ".join(f"a={a:<5}" for a in alphas), flush=True)
    best = None
    for L in layers:
        os_ = []
        for a in alphas:
            tot = cnt = 0
            for s in stems:
                txt = st.gen(s, [L], a)
                p, n = polarity(txt)
                tot += p
                cnt += n
            os_.append(tot / len(stems))
        print(f"{L:>5} {np.linalg.norm(st.delta[L]):6.2f} " +
              " ".join(f"{v:+7.2f}" for v in os_), flush=True)
        spread = max(os_) - min(os_)
        if best is None or spread > best[0]:
            best = (spread, L)
    return best


def _diff(st, layer, alpha, stem, pair):
    ids = np.array(list(st.E.encode(stem)), np.int64)
    lg, _ = st.E.forward(ids, v_delta={layer: ([-1], alpha * st.delta[layer])})
    x = st.E.encode(pair[0])[0]
    y = st.E.encode(pair[1])[0]
    return float(lg[x] - lg[y])


def probe(st, layer=18, alphas=(-4, -2, 0, 2, 4)):
    """确定性 logit 探针: 同一位置的 logit(a) - logit(b), 零采样噪声."""
    print(f"=== logit 探针 @L{layer} (mean over {len(HELD)} held-out stems) ===", flush=True)
    for name, pair in PROBE:
        row = [np.mean([_diff(st, layer, a, s, pair) for s in HELD]) for a in alphas]
        print(f"  {name:22s} " + " ".join(f"{v:+6.2f}" for v in row)
              + f"  d={row[-1] - row[0]:+.2f}", flush=True)
    rng = np.random.default_rng(0)
    d = rng.normal(0, 1, st.delta[layer].shape).astype(np.float32)
    rnd = d / np.linalg.norm(d) * np.linalg.norm(st.delta[layer])
    keep = st.delta[layer]
    st.delta[layer] = rnd
    row = [np.mean([_diff(st, layer, a, s, PROBE[0][1]) for s in HELD]) for a in alphas]
    st.delta[layer] = keep
    print(f"  {'random (norm-matched)':22s} " + " ".join(f"{v:+6.2f}" for v in row)
          + f"  d={row[-1] - row[0]:+.2f}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scan", action="store_true")
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--probe", action="store_true")
    args = ap.parse_args()
    st = Steerer().build(PAIRS, LAYERS)
    if args.probe:
        return probe(st)
    alphas = [0.0, 0.5, 1.0, 2.0, 4.0]
    if args.scan or not args.demo:
        print("=== 层 x alpha 扫描 (mean polarity over 4 stems, 20 tok) ===", flush=True)
        spread, L = scan(st, LAYERS, alphas, STEMS)
        print(f"[best spread] layer={L} spread={spread:.2f}", flush=True)
    if args.demo:
        print("\n=== demo: 单层最优 alpha ===", flush=True)
        for a in [0.0, 1.0, 2.0, 4.0]:
            for s in STEMS[:2]:
                txt = st.gen(s, [16], a)
                p, n = polarity(txt)
                print(f"  a={a:<4} {s!r:28s} pol={p:+d} {txt[:60]!r}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
