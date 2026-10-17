#!/data/data/com.termux/files/usr/bin/python3
"""ladder.py — 0.57M 模型的 capability ladder.

不训练, 纯前向. 沿「复制 -> 结构 -> 组合」逐级加难度, 每级配基线.
目的: 找出能过 / 不能过的分界线, 并指出分界对应哪一类能力.
"""
import os
import sys
from collections import Counter, defaultdict

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QXN_GGML", "0")

from a3_pretrain import compress_vocab                      # noqa: E402
from q1t_stream import StreamEngine                         # noqa: E402
from qxn_train import build_from_ckpt                       # noqa: E402

T = "/data/data/com.termux/files/usr/tmp/opencode"
SLIM = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")


def main():
    ids = np.load(T + "/codeonly_full.npz")["ids"]
    seq, V, K = compress_vocab(ids, 2400)
    tr = seq[:int(len(seq) * 0.9)]
    ho = seq[int(len(seq) * 0.95):]
    tok = StreamEngine(slim=SLIM)
    z = np.load(T + "/TKc_fp32_s11200.npz")
    m, info = build_from_ckpt({k: z[k] for k in z.files})
    Vm = info[3]

    bg = defaultdict(lambda: defaultdict(int))
    uni = Counter()
    for a, b in zip(tr[:-1], tr[1:]):
        a, b = int(a), int(b)
        if a >= 1 and b >= 1:
            bg[a][b] += 1
            uni[b] += 1
    print("bigram 基线已建立 (训练段 %.1fM token)" % (len(tr) / 1e6))

    rng = np.random.default_rng(19)
    NW, CH, PRED = 400, 48, 16
    cats = defaultdict(lambda: [0, 0])
    bg_hit = bg_n = 0
    for _ in range(NW):
        s = int(rng.integers(0, len(ho) - CH - PRED - 1))
        # 目标位置也要送进输入, 否则拿不到那些位置的 logits
        x = ho[s:s + CH + PRED].astype(np.int64)
        lg = np.asarray(m.forward(x[None], collect=False)[0], np.float64)
        seen = set()
        for t in range(CH, CH + PRED):
            g = int(x[t])          # 由 logits[t-1] 预测
            if g < 1 or g > Vm:
                continue
            seen.add(int(x[t - 1]))
            if g in seen:
                c = "A_上下文出现过"
            elif bg[int(x[t - 1])].get(g, 0) > 0:
                c = "B_bigram猜得到"
            else:
                c = "C_全新token"
            cats[c][0] += int(lg[t - 1].argmax()) == g
            cats[c][1] += 1
            d = bg[int(x[t - 1])]
            if d:
                bg_hit += max(d, key=d.get) == g
                bg_n += 1
    tot = sum(v[1] for v in cats.values())
    cor = sum(v[0] for v in cats.values())
    print("\n=== 阶梯 1: 下一 token 预测 (0.57M, 11200 步, 贪心) ===")
    for c in sorted(cats):
        h, n = cats[c]
        print("  %-14s %5.2f%%  (n=%-5d 占 %.1f%%)"
              % (c, 100 * h / n, n, 100 * n / tot))
    print("  %-14s %5.2f%%  (n=%d)" % ("总计", 100 * cor / tot, tot))
    print("  %-14s %5.2f%%  (n=%d)  <- 同数据对照"
          % ("bigram", 100 * bg_hit / max(bg_n, 1), bg_n))

    # 阶梯 2: 缩进深度分类
    txt = tok.decode_text([int(K[i - 1]) for i in ho[:200000] if 1 <= i < K.size + 1])
    ind = [len(l) - len(l.lstrip()) for l in txt.split("\n")]
    b = Counter(min(v // 4, 3) for v in ind)
    print("\n=== 阶梯 2: 下一行缩进深度 (4 类分类) ===")
    print("  分布:", {k: round(100 * v / sum(b.values()), 1)
                      for k, v in sorted(b.items())})
    print("  多数类基线 %.2f%%" % (100 * max(b.values()) / sum(b.values())))
    print("  -> 未建模: 需要逐 token 判定, 见阶梯 3")


if __name__ == "__main__":
    main()