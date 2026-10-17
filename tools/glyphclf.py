"""在合成字形库上训练分类器, 再给图上 142 个聚类打标签。

合成标签来自字体本身, 零人工噪声; 真实标签的一致性是独立检验。
"""
import sys, os, pickle
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np

WORK = '/data/data/com.termux/files/usr/tmp/opencode'


def sm(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -30, 30)))


def train(X, y, ncls, H=192, ep=150, bs=32, lr=2e-3, seed=1, log=True):
    rng = np.random.default_rng(0)
    r2 = np.random.default_rng(seed)
    W1 = r2.standard_normal((X.shape[1], H)) * (1.0 / X.shape[1]) ** 0.5
    b1 = np.zeros(H)
    W2 = r2.standard_normal((H, ncls)) * (1.0 / H) ** 0.5
    b2 = np.zeros(ncls)
    st = [np.zeros_like(W1), np.zeros_like(b1), np.zeros_like(W2), np.zeros_like(b2)]
    vt = [np.zeros_like(W1), np.zeros_like(b1), np.zeros_like(W2), np.zeros_like(b2)]
    perm = rng.permutation(len(X))
    nte = len(X) // 5
    te, tr = perm[:nte], perm[nte:]
    best = 0.0
    for e in range(1, ep + 1):
        o = rng.permutation(len(tr))
        for s in range(0, len(o) - bs + 1, bs):
            b = o[s:s + bs]
            xb, yb = X[tr[b]], y[tr[b]]
            h = sm(xb @ W1 + b1)
            lo = h @ W2 + b2
            lo -= lo.max(axis=1, keepdims=True)
            p = np.exp(lo)
            p /= p.sum(axis=1, keepdims=True)
            p[np.arange(len(b)), yb] -= 1.0
            p /= len(b)
            gh = (p @ W2.T) * (h * (1 - h))
            g = [(xb.T @ gh), gh.sum(axis=0), (h.T @ p), p.sum(axis=0)]
            for P, gP, mP, vP in zip((W1, b1, W2, b2), g, st, vt):
                mP *= 0.9
                mP += 0.1 * gP
                vP *= 0.999
                vP += 0.001 * gP * gP
                P -= lr * (mP / (1 - 0.9 ** e)) / (np.sqrt(vP / (1 - 0.999 ** e)) + 1e-8)
        if e % 25 == 0:
            acc = (sm(X[te] @ W1 + b1) @ W2 + b2).argmax(1).__eq__(y[te]).mean()
            best = max(best, acc)
            if log:
                print('  epoch %3d 留出 %.1f%%' % (e, 100 * acc), flush=True)
    return W1, b1, W2, b2, best


def predict(vec, W1, b1, W2, b2):
    return (sm(vec @ W1 + b1) @ W2 + b2).argmax()


if __name__ == '__main__':
    d = np.load(os.path.join(WORK, 'glyphbank.npz'), allow_pickle=True)
    X, y = d['X'], d['y']
    chars = list(d['chars'])
    print('样本 %d 类别 %d' % (X.shape[0], len(chars)))
    W1, b1, W2, b2, best = train(X, y, len(chars))
    np.savez(os.path.join(WORK, 'glyphclf.npz'), W1=W1, b1=b1, W2=W2, b2=b2,
             chars=np.array(chars, dtype=object), allow_pickle=True)
    print('合成库内留出 %.1f%%  已存 glyphclf.npz' % (100 * best))

    sp = pickle.load(open(os.path.join(WORK, 'clusters.pkl'), 'rb'))['clusters']
    R = 16
    def tovec(g):
        v = np.zeros(R * R, dtype=np.float32)
        for r in range(R):
            for c in range(R):
                if g[r][c]:
                    v[r * R + c] = 1.0
        return v
    out = {}
    for ci, mem in enumerate(sp):
        out[ci] = chars[predict(tovec(mem[0]['grid']), W1, b1, W2, b2)]
    import json
    json.dump(out, open(os.path.join(WORK, 'cluster_pred.json'), 'w'),
              ensure_ascii=False)
    n = len(out)
    print()
    print('对图上 %d 个聚类给出预测 -> cluster_pred.json' % n)
    try:
        from labels import L
        agree = sum(1 for k, v in out.items() if L.get(int(k)) == v)
        print('与我现有标签一致: %d / %d (%.0f%%)' % (agree, n, 100.0 * agree / n))
    except Exception as e:
        print('无法与现有标签比对:', e)
    from collections import Counter
    c = Counter(out.values())
    print('预测字符分布 top15:', c.most_common(15))