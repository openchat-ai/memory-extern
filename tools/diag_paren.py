#!/data/data/com.termux/files/usr/bin/python3
"""diag_paren.py — 括号不闭合是解码问题还是模型能力问题?

判据: 在**真实代码**上, 当上一个 token 是 '(' 时模型给 ')' 的概率如何?
      若真实代码上高、生成上低 -> 解码/复利误差问题
      若真实代码上也低 -> 模型能力问题
另外扫采样参数, 看括号闭合率是否可调.
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QXN_GGML", "0")

OPEN = {"(": ")", "[": "]", "{": "}"}


def balanced(text):
    st = []
    for ch in text:
        if ch in OPEN:
            st.append(OPEN[ch])
        elif ch in ")]}":
            if not st or st[-1] != ch:
                return False
            st.pop()
    return not st


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--vocab", type=int, default=2400)
    ap.add_argument("--data", required=True)
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--max-new", type=int, default=120)
    a = ap.parse_args()

    import sampler
    from a3_pretrain import compress_vocab
    from qxn_train import build_from_ckpt
    from q1t_stream import StreamEngine

    ids = np.load(a.tokens)["ids"]
    seq, V, K = compress_vocab(ids, a.vocab)
    lut = np.zeros(int(K.max()) + 2, np.int64)
    lut[K] = np.arange(1, K.size + 1)
    tok = StreamEngine(slim="/data/data/com.termux/files/home/models/qxt/"
                             "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
    z = np.load(a.ckpt)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, info = build_from_ckpt({k: z[k] for k in z.files}, mode=mode)
    BLK = info[4]
    rid2c = {int(v): chr(int(v)) for v in K if 32 < int(v) < 127}
    # x 里是**压缩槽**, 必须 slot -> 原始 id -> 字符(§48 里踩过同样的坑)
    slot2c = {s: rid2c.get(int(v), "")
              for s, v in zip(range(1, K.size + 1), K)}

    # ---- A) 教师强制: 真实代码里 '(' 后面, 模型给 ')' 的概率 ----
    n = len(seq)
    tr = seq[:int(n * 0.9)]
    rng = np.random.default_rng(0)
    hit = tot = 0
    ranks = []
    for _ in range(2500):
        s0 = int(rng.integers(0, len(tr) - BLK - 2))
        x = tr[s0:s0 + BLK]
        lg = np.asarray(m.forward(x[None], collect=True)[0],
                        np.float64).reshape(BLK, info[3])
        for t in range(BLK - 1):
            if slot2c.get(int(x[t]), "") != "(":
                continue
            r = int(lg[t].argmax())
            rc = slot2c.get(r, "")
            tot += 1
            hit += (rc == ")")
            ranks.append(int((lg[t] > lg[t, r]).sum()))
    print("A) 教师强制, 真实代码中 '(' 之后:")
    if tot:
        print("   %d 个位置   模型直接预测 ')' 的比例 %.1f%%   ')' 在候选中的中位排名 %d"
              % (tot, 100 * hit / tot, int(np.median(ranks))))
    else:
        print("   样本里没有 '('")

    # ---- B) 生成: 采样参数能否改善括号闭合 ----
    rows = [json.loads(l) for l in open(a.data, encoding="utf-8") if l.strip()][:a.n]
    print("\nB) 生成 %.d 题, 括号闭合率:" % a.n)
    for cfg in [(0.0, 0, 1.0), (0.7, 25, 1.0), (0.7, 0, 1.0), (0.4, 25, 1.0)]:
        sampler.TEMP, sampler.TOPK, sampler.REP = cfg
        sampler.ACTIVE = bool(cfg[0] or cfg[1] or cfg[2] != 1.0)
        r2 = np.random.default_rng(0)
        ok = tot = 0
        for row in rows:
            ids_ = [int(t) for t in tok.encode(row["prompt"])]
            tk = [int(lut[i]) for i in ids_ if lut[i] != 0][-BLK:]
            if not tk:
                continue
            for _ in range(a.max_new):
                lg = np.asarray(m.forward(np.array([tk[-BLK:]], np.int64),
                                         collect=False)[0], np.float64)[-1]
                nx = sampler.pick(lg, tk, r2)
                tk.append(nx if nx else int(np.argmax(lg[1:]) + 1))
            real = [int(K[i - 1]) for i in tk[-a.max_new:] if 1 <= i < K.size + 1]
            ok += balanced(tok.decode_text(real))
            tot += 1
        print("   TEMP=%.1f TOPK=%-2d -> 括号闭合 %5.1f%%  (%d/%d)"
              % (cfg[0], cfg[1], 100 * ok / max(tot, 1), ok, tot))


if __name__ == "__main__":
    main()
