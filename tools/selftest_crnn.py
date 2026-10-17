"""crnn.py 的组件自检: 全部通过才允许训练。"""
import sys, math, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import crnn

FAIL = []


def chk(name, got, want, tol=3e-4):
    den = max(float(np.max(np.abs(want))), 1e-8)
    rel = float(np.max(np.abs(got - want))) / den
    ok = rel < tol
    print('  %-28s %.3e  %s' % (name, rel, 'OK' if ok else 'FAIL'))
    if not ok:
        FAIL.append(name)


def fd(f, params, keys):
    eps = 1e-5
    num = {k: np.zeros_like(params[k]) for k in keys}
    for k in keys:
        a = params[k]
        for i in np.ndindex(a.shape):
            o = a[i]
            a[i] = o + eps
            L1 = f()
            a[i] = o - eps
            L2 = f()
            a[i] = o
            num[k][i] = (L1 - L2) / (2 * eps)
    return num


def ref_ctc(lp, lab):
    """独立参照: 枚举全部对齐"""
    T = lp.shape[0]
    ext = [0]
    for l in lab:
        ext += [l, 0]
    S = len(ext)
    paths = []

    def rec(t, s, acc, sq):
        a2 = acc + lp[t, ext[s]]
        s2 = sq + [s]
        if t == T - 1:
            if s in (S - 2, S - 1):
                paths.append((s2, a2))
            return
        for d in (0, 1, 2):
            ns = s + d
            if ns >= S:
                continue
            if d == 2 and ext[ns] == ext[ns - 2]:
                continue
            rec(t + 1, ns, a2, s2)

    for s0 in (0, 1):
        rec(0, s0, 0.0, [])
    Z = sum(math.exp(a) for _, a in paths)
    g = np.zeros_like(lp)
    for sq, a in paths:
        w = math.exp(a) / Z
        for t, s in enumerate(sq):
            g[t, ext[s]] -= w
    return -math.log(Z), g


def main():
    rng = np.random.default_rng(0)
    print('[conv]')
    cv = crnn.Conv(2, 4, 3, 1, 1, rng)
    x = rng.standard_normal((2, 2, 5, 6)) * 0.5
    o = cv.forward(x)
    g = rng.standard_normal(o.shape)
    dx = cv.backward(g)
    n = fd(lambda: (cv.forward(x) * g).sum(), {'w': cv.w, 'b': cv.b}, ['w', 'b'])
    chk('conv dW', cv.dw, n['w'])
    chk('conv db', cv.db, n['b'])
    chk('conv dx', dx, fd(lambda: (cv.forward(x) * g).sum(), {'x': x}, ['x'])['x'])

    print('[maxpool]')
    for kh, kw in ((2, 2), (2, 1), (1, 2)):
        pl = crnn.MaxPool(kh, kw)
        x = rng.standard_normal((2, 3, 8, 8))
        o = pl.forward(x)
        g = rng.standard_normal(o.shape)
        dx = pl.backward(g)
        chk('maxpool %dx%d dx' % (kh, kw), dx,
            fd(lambda: (pl.forward(x) * g).sum(), {'x': x}, ['x'])['x'])

    print('[GRUCell]')
    gc = crnn.GRUCell(3, 4, rng)
    x = rng.standard_normal((2, 6, 3)) * 0.5
    o = gc._run(x)
    g = rng.standard_normal(o.shape)
    dx, gW, gU, gb = gc.backward(g)
    P = {}
    for gg in ('r', 'z', 'n'):
        for nm, arr in (('W', gc.W[gg]), ('U', gc.U[gg]), ('b', gc.b[gg])):
            P['%s%s' % (gg, nm)] = arr
    n = fd(lambda: (gc._run(x) * g).sum(), P, list(P))
    for k in P:
        chk('GRU d' + k, {'W': gW, 'U': gU, 'b': gb}[k[1]][k[0]], n[k])
    chk('GRU dx', dx, fd(lambda: (gc._run(x) * g).sum(), {'x': x}, 'x')['x'])

    print('[Bigram]')
    bg = crnn.Bigram(3, 4, rng)
    x = rng.standard_normal((2, 6, 3)) * 0.5
    o = bg.forward(x)
    g = rng.standard_normal(o.shape)
    dx, gr = bg.backward(g)
    chk('Bigram dx', dx, fd(lambda: (bg.forward(x) * g).sum(), {'x': x}, ['x'])['x'])

    print('[CTC 前向+梯度 对暴力枚举]')
    for T, C, lab in ((2, 5, [1]), (3, 5, [1, 2]), (4, 6, [1, 1, 2]),
                      (5, 5, [2, 2]), (6, 6, [3, 1, 4, 1]), (7, 6, [2, 2, 2])):
        lp = crnn.log_softmax(rng.standard_normal((T, C)), -1)
        ct = crnn.CTC()
        L = ct.forward(lp[None], np.array([lab]), np.array([len(lab)]))
        g = ct.backward(1.0)[0]
        rL, rg = ref_ctc(lp, lab)
        chk('T=%d loss' % T, L, rL, 1e-9)
        chk('T=%d 梯度' % T, g, rg, 1e-7)

    print('[CTC 端到端 梯度]')
    for N, T, C, lab, ln in ((1, 6, 5, [[1, 2, 3]], [3]),
                              (3, 7, 6, [[1, 2, 3, 0], [4, 5, 0, 0], [2, 2, 0, 0]],
                               [3, 2, 2])):
        lg = rng.standard_normal((N, T, C))
        ct = crnn.CTC()
        ct.forward(crnn.log_softmax(lg, -1), np.array(lab), np.array(ln))
        g = crnn.log_softmax_backward(ct.backward(1.0), lg)
        nn = fd(lambda: crnn.CTC().forward(crnn.log_softmax(lg, -1),
                                           np.array(lab), np.array(ln)),
                {'logits': lg}, ['logits'])
        chk('CTC dlogits N=%d' % N, g, nn['logits'], 2e-3)

    print()
    if FAIL:
        print('自检失败:', FAIL)
        return 1
    print('自检全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())