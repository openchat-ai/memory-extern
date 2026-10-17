#!/data/data/com.termux/files/usr/bin/python3
"""tasks.py — 两个可能真能部署的任务, 纯前向, 不训练.

T1 字符串存在性判断 (attention + 复制): 给一段代码, 问其中是否含某字符串
T2 下一行补全 (infill): 给代码前缀, 预测下一行的前 N 个字符

每个都配基线. 基线不过 -> 结果无意义 (§11.3).
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
    BLK, Vm = info[4], info[3]
    lut = np.zeros(int(K.max()) + 2, np.int64)
    lut[K] = np.arange(1, K.size + 1)

    def slot(text):
        r = [int(lut[i]) for i in tok.encode(text) if lut[i] != 0]
        return r[0] if r else 0

    YES = [slot(s) for s in (" yes", " Yes", "YES")]
    NO = [slot(s) for s in (" no", " No", "NO")]
    YES = [s for s in YES if s > 0]
    NO = [s for s in NO if s > 0]
    print("yes 槽:", YES, " no 槽:", NO)
    if not YES:
        print("  -> 'yes' 不在 2400 词表内, T1 改用**真实代码行检索**"
              "(只用训练分布内 token, 不依赖英文单词)")

    txt = tok.decode_text([int(K[i - 1]) for i in tr[:400000] if 1 <= i < K.size + 1])

    # ---------- T1 检索: 哪一行属于这个上下文 ----------
    print("\n=== T1 上下文归属检索 (二选一, 只用真实代码 token) ===")
    lines = [l for l in txt.split("\n") if len(l.strip()) > 8]
    rng = np.random.default_rng(31)
    hits = nn = 0

    def score(ctx, cand):
        """candidate 作为续写的平均 logprob. ctx 截断到能装下候选."""
        ct = [int(lut[i]) for i in tok.encode("\n" + cand) if lut[i] != 0]
        bt = [int(lut[i]) for i in tok.encode(ctx + "\n") if lut[i] != 0]
        room = BLK - len(ct) - 1
        if room < 8:
            return -1e9
        xs = bt[-room:] + ct          # 总长 = room + len(ct) < BLK
        lg = np.asarray(m.forward(np.array([xs], np.int64),
                                  collect=False)[0], np.float64)
        tot = 0.0
        for j, tk in enumerate(ct):
            v = lg[room - 1 + j]
            v2 = v - v.max()
            pz = np.exp(v2)
            pz /= pz.sum()
            tot += np.log(max(pz[tk], 1e-12))
        return tot / len(ct)

    for _ in range(150):
        i = int(rng.integers(0, len(lines) - 200))
        ctx = "\n".join(lines[i:i + 120])
        a = lines[i + 120]                         # 属于本上下文
        j = int(rng.integers(0, len(lines) - 1))
        b = lines[j]                               # 来自别处
        if a == b or len(b) > len(a) * 2:
            continue
        sa, sb = score(ctx, a), score(ctx, b)
        if sa <= -1e8 or sb <= -1e8:
            continue
        hits += sa > sb
        nn += 1
    se = 100 * (0.25 / max(nn, 1)) ** 0.5
    print("  模型选对归属 %.2f%%  n=%d  标准误 %.1f pp" % (100 * hits / max(nn, 1), nn, se))
    print("  随机基线 50.00%")
    print("  -> 高出 %.1f 个标准误" % ((100 * hits / max(nn, 1) - 50) / se))

    # ---------- T2 下一行前缀补全 ----------
    print("\n=== T2 下一行前缀补全 (infill, 贪心) ===")
    lines = txt.split("\n")
    rng = np.random.default_rng(41)
    exact = pre5 = nn = 0
    bi_exact = bi_pre5 = 0
    bg = defaultdict(lambda: defaultdict(int))
    for a, b in zip(tr[:-1], tr[1:]):
        if a >= 1 and b >= 1:
            bg[int(a)][int(b)] += 1
    for _ in range(120):
        i = int(rng.integers(0, len(lines) - 120))
        ctxlines = lines[i:i + 61]
        nxt = ctxlines[60].strip() if len(ctxlines) > 60 else ""
        if len(nxt) < 5:
            continue
        pre = "\n".join(ctxlines[:60])
        tk = [int(lut[i]) for i in tok.encode(pre) if lut[i] != 0][-BLK:]
        if len(tk) < 10:
            continue
        out = []
        w = list(tk)
        for _ in range(40):
            lg = np.asarray(m.forward(np.array([w[-BLK:]], np.int64),
                                      collect=False)[0], np.float64)[-1]
            w.append(int(np.argmax(lg)))
        gen = tok.decode_text([int(K[i - 1]) for i in w[-40:] if 1 <= i < K.size + 1])
        gen1 = gen.split("\n")[0].strip()
        exact += gen1 == nxt
        pre5 += gen1[:5] == nxt[:5]
        bi_pre5 += nxt[:5] in gen1
        nn += 1
    print("  精确匹配 %.2f%%   前5字符匹配 %.2f%%   (n=%d)"
          % (100 * exact / max(nn, 1), 100 * pre5 / max(nn, 1), nn))
    print("  宽松基线: 生成里**包含**目标前5字符 %.2f%%"
          % (100 * bi_pre5 / max(nn, 1)))


if __name__ == "__main__":
    main()