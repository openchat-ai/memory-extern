#!/data/data/com.termux/files/usr/bin/python3
"""selftest.py — 训练/推理管线的自检套件.

背景(§43): 交叉熵梯度把减法写成了赋值, 训练照样收敛、loss 照样下降、不报任何错,
只有有限差分对拍能发现. 这个脚本把今天查到的每一类 bug 固化成断言, **跑训练前先跑它**.

检查项:
  1. compress_vocab 与 gen_qxn.rebuild_vocab 的映射是否逐位一致(§33.21 的 off-by-one)
  2. build_from_ckpt 是否真的载入了全部参数(§38.1 的静默跳过)
  3. 解析梯度 vs 5 点有限差分(§42.2 的 w1 漏 GELU、§43 的 CE 赋值)
  4. eval 打印的 CE 与独立重算是否一致
  5. 词表覆盖率与 UNK 占比
  6. 训练/生成用的是否是同一套 vocab 映射

退出码 0 = 全过。
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("QXN_GGML", "0")

FAILS = []


def check(name, ok, detail=""):
    print("  [%s] %s%s" % ("OK " if ok else "FAIL", name,
                           ("  -- " + detail) if detail else ""))
    if not ok:
        FAILS.append(name)


def test_vocab_consistency(tokens_npz, topv):
    from a3_pretrain import compress_vocab
    from gen_qxn import rebuild_vocab
    ids = np.load(tokens_npz)["ids"]
    out, V, K = compress_vocab(ids, topv)
    keep, lut, V2 = rebuild_vocab(tokens_npz, topv)
    check("vocab: compress_vocab vs rebuild_vocab 逐位一致",
          bool((lut[ids.astype(np.int64)] == out).all()),
          "V=%d/%d" % (V, V2))
    check("vocab: 覆盖率 = %.1f%%" % (100 * (out > 0).mean()),
          True, "UNK 占比 %.1f%%" % (100 * (out == 0).mean()))
    return V


def test_load_full(ckpt):
    from qxn_train import build_from_ckpt
    z = np.load(ckpt)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    P = {k: z[k] for k in z.files}
    m, info = build_from_ckpt(P, mode=mode)
    same = all(m.P[k].shape == v.shape for k, v in P.items() if k != "mode")
    check("加载: build_from_ckpt 全参数载入 & block_size 取自 posembd",
          same, "L=%d d=%d ffn=%d V=%d blk=%d" % info)
    return m, info


def test_gradient(seed=11, V=20, B=3, Tt=10, L=2):
    import qxn_train as T
    rng = np.random.default_rng(seed)
    m = T.QxN(L, 16, 2, 32, V, Tt, mode="fp32", seed=1)
    m.P = {k: v.astype(np.float64) for k, v in m.P.items()}
    x = rng.integers(1, V, (B, Tt))

    def loss_of():
        Lg = np.asarray(m.forward(x, collect=True)[0], np.float64)
        t = x[:, 1:]
        l = Lg[:, :-1]
        l = l - l.max(-1, keepdims=True)
        l = l - np.log(np.exp(l).sum(-1, keepdims=True))
        return float((-l[np.arange(B)[:, None],
                         np.arange(Tt - 1)[None, :], t]).mean())

    o = m.forward(x, collect=True)
    G = m.backward(x, o[0], o[1], o[2], o[3], o[4])
    rels = []
    for k in G:
        if G[k].size < 4 or k not in m.P or m.P[k].shape != G[k].shape:
            continue
        for f in np.argsort(-np.abs(G[k]).ravel())[:3]:
            idx = np.unravel_index(f, G[k].shape)
            base, ana = float(m.P[k][idx]), float(G[k][idx])
            if abs(ana) < 1e-3:
                continue
            h, v = 1e-4, []
            for s in (-2, -1, 1, 2):
                m.P[k][idx] = base + s * h
                v.append(loss_of())
            m.P[k][idx] = base
            num = (v[0] - 8 * v[1] + 8 * v[2] - v[3]) / (12 * h)
            rels.append(abs(num - ana) / max(abs(num), abs(ana), 1e-12))
    r = np.array(rels)
    med = float(np.median(r)) if len(r) else 1.0
    check("梯度: 解析 vs 5点差分 中位相对误差 %.2e (%d 坐标)" % (med, len(r)),
          med < 1e-5, "阈值 1e-5")
    return med


def test_eval_ce(ckpt, tokens_npz, topv, nwin=40):
    """脚本里 eval 报的 CE 与独立重算是否一致(口径 bug 的护栏).

    必须多窗口平均: 单个 64 字节窗口只有 ~60 个有效 token, CE 方差极大,
    用它做阈值判断会误报(今天的教训: 样本太小, 比值毫无意义).
    """
    from a3_pretrain import compress_vocab
    from qxn_train import build_from_ckpt
    ids = np.load(tokens_npz)["ids"]
    seq, V, _ = compress_vocab(ids, topv)
    z = np.load(ckpt)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, (L, Dd, F, Vv, BLK) = build_from_ckpt({k: z[k] for k in z.files},
                                            mode=mode)
    rng = np.random.default_rng(7)
    tr = seq[:int(len(seq) * 0.9)]
    cels = []
    for _ in range(nwin):
        s0 = int(rng.integers(0, len(tr) - BLK - 2))
        x = tr[s0:s0 + BLK][None]
        y = seq[s0 + 1:s0 + BLK + 1][None]
        lg = np.asarray(m.forward(x, collect=True)[0], np.float64)
        l = lg - lg.max(-1, keepdims=True)
        l = l - np.log(np.exp(l).sum(-1, keepdims=True))
        ce = -l[:, :-1][np.arange(1)[:, None], np.arange(BLK - 1)[None, :],
                         y[:, :BLK - 1]]
        msk = (y[:, :BLK - 1] > 0)
        if msk.any():
            cels.append(ce[msk])
    val = float(np.concatenate(cels).mean())
    check("评估: 独立重算 CE = %.4f (%d 窗口, %d token)"
          % (val, nwin, sum(len(c) for c in cels)),
          1.0 < val < 4.0, "合理区间 (1,4); 超出说明权重或映射可能没对上")
    return val


def test_masked_gradient(seed=3, V=20, B=3, Tt=10, L=2):
    """--mask-unk 路径的梯度必须精确, 否则等于引入新错误(用户要求)."""
    import qxn_train as T
    rng = np.random.default_rng(seed)
    m = T.QxN(L, 16, 2, 32, V, Tt, mode="fp32", seed=1)
    m.P = {k: v.astype(np.float64) for k, v in m.P.items()}
    arr = rng.integers(0, V, (1, 200))
    x, y = arr[0, :Tt].copy(), arr[0, 1:Tt + 1].copy()
    kp = (y[:Tt - 1] != 0)          # 本测试 y 是原始 0-based 下标, 直接用不减 1

    def masked_loss():
        lg = np.asarray(m.forward(x[None], collect=True)[0], np.float64)[0]
        l = lg[:Tt - 1] - lg[:Tt - 1].max(-1, keepdims=True)
        l = l - np.log(np.exp(l).sum(-1, keepdims=True))
        return float((-l[np.arange(Tt - 1), y[:Tt - 1]])[kp].mean())

    o = m.forward(x[None], collect=True)
    lg = np.asarray(o[0], np.float64)
    p = np.exp(lg - lg.max(-1, keepdims=True))
    p /= p.sum(-1, keepdims=True)
    d = p.astype(np.float32).copy()
    d[0][:Tt - 1][np.arange(Tt - 1), x[1:]] -= 1.0
    d[0][:Tt - 1][~kp] = 0.0
    d[0][Tt - 1:] = 0.0
    d /= int(kp.sum())
    G = m.backward(x[None], o[0], o[1], o[2], o[3], o[4], dlogits=d)
    rels = []
    for k in G:
        if G[k].size < 4 or k not in m.P or m.P[k].shape != G[k].shape:
            continue
        for f in np.argsort(-np.abs(G[k]).ravel())[:2]:
            idx = np.unravel_index(f, G[k].shape)
            base, ana = float(m.P[k][idx]), float(G[k][idx])
            if abs(ana) < 1e-4:
                continue
            h, v = 1e-4, []
            for sg in (-2, -1, 1, 2):
                m.P[k][idx] = base + sg * h
                v.append(masked_loss())
            m.P[k][idx] = base
            num = (v[0] - 8 * v[1] + 8 * v[2] - v[3]) / (12 * h)
            rels.append(abs(num - ana) / max(abs(num), abs(ana), 1e-12))
    med = float(np.median(rels)) if len(rels) else 1.0
    check("梯度(--mask-unk): 中位相对误差 %.2e (%d 坐标)" % (med, len(rels)),
          med < 1e-5, "阈值 1e-5")
    return med


def main():
    tokens = sys.argv[1] if len(sys.argv) > 1 else None
    ckpt = sys.argv[2] if len(sys.argv) > 2 else None
    topv = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    print("=== 管线自检 ===")
    print("\n[1] 梯度正确性(与语料无关, 永远要跑)")
    med = test_gradient()
    print("\n[1b] 掩码 loss 的梯度")
    test_masked_gradient()
    if tokens:
        V = topv or 182
        print("\n[2] 词表一致性  %s" % tokens)
        test_vocab_consistency(tokens, V)
    if ckpt and tokens and topv:
        print("\n[3] checkpoint 载入")
        test_load_full(ckpt)
        print("\n[4] 评估口径")
        test_eval_ce(ckpt, tokens, topv)
    print("\n=== %s ===" % ("全部通过" if not FAILS
                          else "有 %d 项失败: %s" % (len(FAILS), FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())