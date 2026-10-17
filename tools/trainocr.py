"""trainocr.py — 用聚类标签训练一个 CAD 字形分类器，替代人工辨认。

输入: 16x16 二值位图(与 tools/glyph.py 的 raster() 同口径)
输出: 142 个簇的分类
价值: 认认同类的所有实例，而非只能认某一张图里的某几个簇样本。

用法:  python3 tools/trainocr.py <paths.pkl> <labels.py>
"""
import pickle
import sys
import time

import numpy as np

RASTER = 16
HID = 128
EPOCHS = 60
BATCH = 32
LR = 0.01
SEED = 12345


def load_labels(mod):
    import importlib
    m = importlib.import_module(mod)
    return dict(m.L)


def extract(sp, cl, labs):
    """遍历所有文字行，把每个字形栅格化成特征。

    输出类别是**字符**而非簇号：142 簇只对应 74 个字符，
    同字符的不同字号被拆成多个簇，按簇训练等于让模型去记字号。
    """
    chars = sorted(set(labs.values()))
    ch2i = {c: i for i, c in enumerate(chars)}
    sys.path.insert(0, '/data/data/com.termux/files/home/sram/tools')
    import glyph
    G = glyph.cluster_paths(sp)
    R = glyph.runs(G)
    X, Y, meta = [], [], []
    for run in R:
        ang = glyph.run_angle(run)
        b = glyph.bbox_of(run)
        for g in run:
            cx = (g['xa'] + g['xb']) / 2
            cy = (g['ya'] + g['yb']) / 2
            gr = glyph.raster(sp, g['paths'], cx, cy, ang)
            if gr is None:
                continue
            bd, bc = None, None
            for k, c in enumerate(cl):
                d = glyph.dist(gr, c[0]['grid'])
                if bd is None or d < bd:
                    bd, bc = d, k
            if bc is None or bc not in labs or bc >= len(cl):
                continue
            X.append(np.array(gr, dtype=np.float32).ravel())
            Y.append(ch2i[labs[bc]])
            meta.append((b['xa'], b['yb'], labs[bc], b['h_med']))
    return np.array(X), np.array(Y), meta


def augment(X, Y, rng):
    """随机平移/加噪，扩展小样本。"""
    n = len(X)
    extra = 2 * n
    Xa = np.zeros((n + extra, RASTER * RASTER), dtype=np.float32)
    Ya = np.zeros(n + extra, dtype=np.int64)
    Xa[:n] = X
    Ya[:n] = Y
    for i in range(n, n + extra):
        j = int(rng.integers(0, n))
        dx, dy = rng.integers(-1, 2, size=2)
        g = X[j].reshape(RASTER, RASTER)
        g2 = np.roll(np.roll(g, dy, axis=0), dx, axis=1)
        Xa[i] = g2.ravel() + rng.normal(0, 0.02, g2.size)
        Ya[i] = Y[j]
    return np.clip(Xa, 0, 1), Ya


def main():
    sp = pickle.load(open(sys.argv[1], 'rb'))
    cl = pickle.load(open('clusters.pkl', 'rb'))['clusters']
    labs = load_labels('labels')
    X, Y, meta = extract(sp, cl, labs)
    n = len(X)
    chars = sorted(set(labs.values()))
    nc = len(chars)
    print('样本 %d, 字符类别 %d (簇 %d)' % (n, nc, len(labs)))

    rng = np.random.default_rng(SEED)
    idx = rng.permutation(n)
    cut = int(n * 0.8)
    tr, te = idx[:cut], idx[cut:]
    Xtr, Ytr = X[tr], Y[tr]
    Xte, Yte = X[te], Y[te]
    Xtr, Ytr = augment(Xtr, Ytr, rng)
    print('训练 %d(含增广), 留出 %d' % (len(Xtr), len(Xte)))

    W1 = rng.normal(0, .1, (RASTER * RASTER, HID)).astype(np.float32)
    b1 = np.zeros(HID, np.float32)
    W2 = rng.normal(0, .1, (HID, HID)).astype(np.float32)
    b2 = np.zeros(HID, np.float32)
    W3 = rng.normal(0, .1, (HID, nc)).astype(np.float32)
    b3 = np.zeros(nc, np.float32)
    params = [W1, b1, W2, b2, W3, b3]
    ms = [np.zeros_like(p) for p in params]
    vs = [np.zeros_like(p) for p in params]
    mW = np.zeros_like(W3)
    vW = np.zeros_like(W3)
    step = 0
    t0 = time.time()
    for ep in range(EPOCHS):
        perm = rng.permutation(len(Xtr))
        for s in range(0, len(perm), BATCH):
            bi = perm[s:s + BATCH]
            xb, yb = Xtr[bi], Ytr[bi]
            z1 = xb @ W1 + b1
            a1 = np.maximum(z1, 0)
            z2 = a1 @ W2 + b2
            a2 = np.maximum(z2, 0)
            z3 = a2 @ W3 + b3
            z3 -= z3.max(axis=1, keepdims=True)
            e = np.exp(z3)
            p = e / e.sum(axis=1, keepdims=True)
            dz = p.copy()
            dz[np.arange(len(yb)), yb] -= 1
            dz /= len(yb)
            gW3 = a2.T @ dz
            gb3 = dz.sum(axis=0)
            da2 = (dz @ W3.T) * (z2 > 0)
            gW2 = a1.T @ da2
            gb2 = da2.sum(axis=0)
            da1 = (da2 @ W2.T) * (z1 > 0)
            gW1 = xb.T @ da1
            gb1 = da1.sum(axis=0)
            grads = [gW1, gb1, gW2, gb2, gW3, gb3]
            step += 1
            for i, (p_, g_) in enumerate(zip(params, grads)):
                ms[i] = .9 * ms[i] + .1 * g_
                vs[i] = .999 * vs[i] + .001 * g_ * g_
                mh = ms[i] / (1 - .9 ** step)
                vh = vs[i] / (1 - .999 ** step)
                p_ -= LR * mh / (np.sqrt(vh) + 1e-8)
        if (ep + 1) % 10 == 0 or ep == 0:
            z = Xte @ W1 + b1
            z = np.maximum(z, 0) @ W2 + b2
            z = np.maximum(z, 0) @ W3 + b3
            acc = (z.argmax(1) == Yte).mean()
            print('  epoch %2d  留出准确率 %.4f  (%.1fs)' % (ep + 1, acc, time.time() - t0))
    z = Xte @ W1 + b1
    z = np.maximum(z, 0) @ W2 + b2
    z = np.maximum(z, 0) @ W3 + b3
    pred = z.argmax(1)
    acc = (pred == Yte).mean()
    print()
    print('留出集逐字准确率 %.4f  (%d/%d)' % (acc, (pred == Yte).sum(), len(Yte)))
    # 逐行准确率：一行全对才算解出
    rows = {}
    for i, ti in enumerate(te):
        rows.setdefault((meta[ti][0], meta[ti][1]), []).append(pred[i] == Yte[i])
    full = sum(1 for v in rows.values() if all(v))
    print('逐行全对 %d / %d 行 (%.1f%%)' % (full, len(rows), 100 * full / len(rows)))
    np.savez('ocr_model.npz', W1=W1, b1=b1, W2=W2, b2=b2, W3=W3, b3=b3,
             chars=np.array(chars, dtype=object), allow_pickle=True)


if __name__ == '__main__':
    main()