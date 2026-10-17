"""纯 numpy 的 CRNN + CTC, 供转曲 CAD 行级 OCR 使用。

各组件均有有限差分对拍 (selftest), 未通过不得用于训练。
"""
import numpy as np


def im2col(x, kh, kw, stride, pad):
    N, C, H, W = x.shape
    OH = (H + 2 * pad - kh) // stride + 1
    OW = (W + 2 * pad - kw) // stride + 1
    xp = np.pad(x, ((0, 0), (0, 0), (pad, pad), (pad, pad)))
    cols = np.zeros((N, C * kh * kw, OH * OW), dtype=x.dtype)
    idx = 0
    for c in range(C):
        for i in range(kh):
            for j in range(kw):
                sub = xp[:, c, i:i + stride * OH:stride, j:j + stride * OW:stride]
                cols[:, idx, :] = sub.reshape(N, -1)
                idx += 1
    return cols, OH, OW


def col2im(cols, shape, kh, kw, stride, pad):
    N, C, H, W = shape
    OH = (H + 2 * pad - kh) // stride + 1
    OW = (W + 2 * pad - kw) // stride + 1
    xp = np.zeros((N, C, H + 2 * pad, W + 2 * pad), dtype=cols.dtype)
    idx = 0
    for c in range(C):
        for i in range(kh):
            for j in range(kw):
                view = xp[:, c, i:i + stride * OH:stride, j:j + stride * OW:stride]
                view += cols[:, idx, :].reshape(N, OH, OW)
                idx += 1
    return xp[:, :, pad:pad + H, pad:pad + W]


def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -30, 30)))


def logsumexp(a, axis=-1):
    m = np.max(a, axis=axis, keepdims=True)
    m = np.where(np.isfinite(m), m, 0.0)
    return (m + np.log(np.sum(np.exp(a - m), axis=axis, keepdims=True))).squeeze(axis)


class Conv:
    def __init__(self, cin, cout, k=3, stride=1, pad=1, rng=None):
        self.w = (rng.standard_normal((cout, cin * k * k)) * (2.0 / (cin * k * k)) ** 0.5)
        self.b = np.zeros(cout)
        self.k, self.stride, self.pad = k, stride, pad
        self.cin, self.cout = cin, cout

    def forward(self, x):
        self.x = x
        cols, OH, OW = im2col(x, self.k, self.k, self.stride, self.pad)
        self.cols = cols
        self.OH, self.OW = OH, OW
        N = x.shape[0]
        o = self.w @ cols + self.b[:, None]
        return o.reshape(N, self.cout, OH, OW)

    def backward(self, dout):
        N = dout.shape[0]
        d = dout.reshape(N, self.cout, -1)
        self.dw = np.einsum('nol,nkl->ok', d, self.cols)
        self.db = d.sum(axis=(0, 2))
        dcols = self.w.T @ d
        return col2im(dcols, self.x.shape, self.k, self.k, self.stride, self.pad)


class MaxPool:
    def __init__(self, kh, kw, stride=None):
        self.kh, self.kw = kh, kw
        self.stride = stride if stride else (kh, kw)

    def forward(self, x):
        N, C, H, W = x.shape
        sh, sw = self.stride
        OH, OW = H // sh, W // sw
        self.x = x
        self.shape = (N, C, OH, OW)
        xp = x[:, :, :OH * sh, :OW * sw].reshape(N, C, OH, sh, OW, sw)
        xp = xp.transpose(0, 1, 2, 4, 3, 5).reshape(N, C, OH * OW, sh * sw)
        self.win = xp
        idx = xp.argmax(axis=3)
        out = xp.max(axis=3)
        self.mask = np.zeros_like(xp, dtype=bool)
        np.put_along_axis(self.mask, idx[:, :, :, None], True, axis=3)
        return out.reshape(N, C, OH, OW)

    def backward(self, dout):
        assert tuple(dout.shape) == tuple(self.shape),             'maxpool 梯度形状与前向不符: %s vs %s' % (dout.shape, self.shape)
        N, C, OH, OW = self.shape
        sh, sw = self.stride
        d = dout.reshape(N, C, OH * OW, 1) * self.mask
        d = d.reshape(N, C, OH, OW, sh, sw).transpose(0, 1, 2, 4, 3, 5)
        return d.reshape(N, C, OH * sh, OW * sw)


class GRUCell:
    """单向 GRU, 每个方向一套参数。

    r_t = σ(Wr x + Ur h + br)
    z_t = σ(Wz x + Uz h + bz)
    n_t = tanh(Wn x + bn + r_t ⊙ (Un h))
    h_t = (1-z_t) ⊙ n_t + z_t ⊙ h_{t-1}
    """

    GATES = ('r', 'z', 'n')

    def __init__(self, cin, hid, rng=None):
        s = 1.0 / max(1.0, float(hid) ** 0.5)
        self.cin, self.hid = cin, hid
        self.W = {}
        self.U = {}
        self.b = {}
        for g in self.GATES:
            self.W[g] = rng.uniform(-s, s, (hid, cin))
            self.U[g] = rng.uniform(-s, s, (hid, hid))
            self.b[g] = np.zeros(hid)

    def backward(self, dout):
        """dout: (N,T,hid) -> (dx, grads)"""
        N, T, _ = dout.shape
        dx = np.zeros((N, T, self.cin))
        gW = {g: np.zeros((self.hid, self.cin)) for g in self.GATES}
        gU = {g: np.zeros((self.hid, self.hid)) for g in self.GATES}
        gb = {g: np.zeros(self.hid) for g in self.GATES}
        dh = np.zeros((N, self.hid))
        for t in range(T - 1, -1, -1):
            xi, h, r, z, n = self.cache[t]
            d = dout[:, t, :] + dh
            dn = d * (1 - z)
            dz = d * (h - n)
            dh = d * z
            dnp = dn * (1 - n * n)
            uhn = (self.U['n'] @ h.T).T
            dr = dnp * uhn
            dnh = dnp * r
            dzp = dz * z * (1 - z)
            drp = dr * r * (1 - r)
            dh = (dh + dnh @ self.U['n'] + dzp @ self.U['z'] + drp @ self.U['r'])
            gW['n'] += dnp.T @ xi
            gU['n'] += dnh.T @ h
            gb['n'] += dnp.sum(axis=0)
            gW['z'] += dzp.T @ xi
            gU['z'] += dzp.T @ h
            gb['z'] += dzp.sum(axis=0)
            gW['r'] += drp.T @ xi
            gU['r'] += drp.T @ h
            gb['r'] += drp.sum(axis=0)
            dx[:, t, :] = dzp @ self.W['z'] + drp @ self.W['r'] + dnp @ self.W['n']
        return dx, gW, gU, gb

    def _run(self, x):
        self.cache = []
        h = np.zeros((x.shape[0], self.hid))
        out = []
        for t in range(x.shape[1]):
            xi = x[:, t, :]
            uh = {g: (self.U[g] @ h.T).T for g in self.GATES}
            z = sigmoid(xi @ self.W['z'].T + uh['z'] + self.b['z'])
            r = sigmoid(xi @ self.W['r'].T + uh['r'] + self.b['r'])
            n = np.tanh(xi @ self.W['n'].T + self.b['n'] + r * uh['n'])
            hnew = (1 - z) * n + z * h
            self.cache.append((xi, h, r, z, n))
            out.append(hnew)
            h = hnew
        return np.stack(out, axis=1)

    def run(self, x):
        return self._run(x)

    def bw(self, dout):
        return self.backward(dout)


class Bigram:
    """双向 GRU: 两个方向共用上面的 GRUCell 实现。"""

    def __init__(self, cin, hid, rng=None):
        self.f = GRUCell(cin, hid, rng)
        self.r = GRUCell(cin, hid, rng)
        self.hid = hid

    def forward(self, x):
        hf = self.f._run(x)
        hr = self.r._run(x[:, ::-1, :])[:, ::-1, :]
        return np.concatenate([hf, hr], axis=2)

    def backward(self, dout):
        df, dr = dout[:, :, :self.hid], dout[:, :, self.hid:]
        dx1, gW1, gU1, gb1 = self.f.backward(df)
        dx2, gW2, gU2, gb2 = self.r.backward(dr[:, ::-1, :])
        grads = {}
        for tag, (gW, gU, gb) in (('f', (gW1, gU1, gb1)), ('r', (gW2, gU2, gb2))):
            for g in self.f.GATES:
                grads['%s_%s_W' % (tag, g)] = gW[g]
                grads['%s_%s_U' % (tag, g)] = gU[g]
                grads['%s_%s_b' % (tag, g)] = gb[g]
        return dx1 + dx2[:, ::-1, :], grads


class Linear:
    def __init__(self, cin, cout, rng=None):
        self.w = rng.standard_normal((cout, cin)) * (1.0 / cin) ** 0.5
        self.b = np.zeros(cout)

    def forward(self, x):
        self.x = x
        return x @ self.w.T + self.b

    def backward(self, dout):
        N = dout.shape[0]
        flat = dout.reshape(-1, dout.shape[-1])
        self.dw = flat.T @ self.x.reshape(-1, self.x.shape[-1]) / flat.shape[0]
        self.db = flat.mean(axis=0)
        return dout @ self.w


def log_softmax(x, axis=-1):
    m = x.max(axis=axis, keepdims=True)
    z = x - m
    return z - np.log(np.exp(z).sum(axis=axis, keepdims=True))


def log_softmax_backward(dlp, logits):
    """y=log_softmax(x) 的反向: dx = dy - softmax(y) * sum(dy)"""
    p = np.exp(log_softmax(logits, axis=-1))
    return dlp - p * dlp.sum(axis=-1, keepdims=True)


class CTC:
    """blank=0, 标签 1..C-1。"""

    def forward(self, logp, labels, lens):
        N, T, C = logp.shape
        self.logp, self.labels, self.lens = logp, labels, lens
        self.cache = []
        total = 0.0
        grads = np.zeros_like(logp)
        for b in range(N):
            lab = labels[b, :lens[b]]
            L = len(lab)
            if L == 0:
                self.cache.append(None)
                continue
            ext = np.empty(2 * L + 1, dtype=int)
            ext[0::2] = 0
            ext[1::2] = lab
            S = len(ext)
            if T < L:
                total += 1e6
                self.cache.append(None)
                continue
            neg = -1e30
            a = np.full((T, S), neg)
            a[0, 0] = logp[b, 0, ext[0]]
            if S > 1:
                a[0, 1] = logp[b, 0, ext[1]]
            for t in range(1, T):
                c = [a[t - 1, :]]
                c.append(np.concatenate([np.full(N_ := 1, neg), a[t - 1, :-1]]))
                cand = np.stack(c)
                if S > 2:
                    prev2 = np.concatenate([np.full(2, neg), a[t - 1, :-2]])
                    allow = (ext != np.concatenate([[-1, -1], ext[:-2]]))
                    prev2 = np.where(allow, prev2, neg)
                    cand = np.concatenate([cand, prev2[None, :]], axis=0)
                a[t] = logp[b, t, ext] + logsumexp(cand, axis=0)
            lp = logsumexp(a[T - 1, S - 2:S])
            total -= lp
            beta = np.full((T, S), neg)
            beta[T - 1, S - 1] = logp[b, T - 1, ext[S - 1]]
            if S > 1:
                beta[T - 1, S - 2] = logp[b, T - 1, ext[S - 2]]
            for t in range(T - 2, -1, -1):
                c0 = beta[t + 1, :]
                c1 = np.concatenate([beta[t + 1, 1:], [neg]])
                if S > 2:
                    nxt2 = np.concatenate([beta[t + 1, 2:], [neg, neg]])
                    allow = (ext != np.concatenate([ext[2:], [-1, -1]]))
                    c2 = np.where(allow, nxt2, neg)
                else:
                    c2 = np.full(S, neg)
                beta[t] = logsumexp(np.stack([c0, c1, c2]), axis=0) + logp[b, t, ext]
            # alpha 与 beta 都含本帧发射量, 相乘时 t 帧被计两次, 需除掉
            ab = a + beta - logp[b][:, ext] - lp
            for t in range(T):
                for s in range(S):
                    if np.isfinite(ab[t, s]):
                        grads[b, t, ext[s]] -= np.exp(ab[t, s])
            self.cache.append((a, beta, ext, lp, S))
        self.grads = grads
        return total / max(N, 1)

    def backward(self, gscale=1.0):
        N = self.logp.shape[0]
        return self.grads * gscale / max(N, 1)


class Adam:
    def __init__(self, params, lr=2e-3):
        self.p = params
        self.lr = lr
        self.m = {k: np.zeros_like(v) for k, v in params.items()}
        self.v = {k: np.zeros_like(v) for k, v in params.items()}
        self.t = 0

    def step(self, grads):
        self.t += 1
        b1, b2, eps = 0.9, 0.999, 1e-8
        for k, p in self.p.items():
            g = grads[k]
            self.m[k] = b1 * self.m[k] + (1 - b1) * g
            self.v[k] = b2 * self.v[k] + (1 - b2) * g * g
            mh = self.m[k] / (1 - b1 ** self.t)
            vh = self.v[k] / (1 - b2 ** self.t)
            p -= self.lr * mh / (np.sqrt(vh) + eps)


def crnn_forward(img, convs, pools, gru, head):
    """img: (N,1,32,W) -> logp (N,T',C)"""
    x = img
    for c, p in zip(convs, pools):
        x = c.forward(x)
        x = p.forward(x)
    N, C, H, W = x.shape
    x = x.mean(axis=2)
    x = x.transpose(0, 2, 1)
    x = gru.forward(x)
    logits = head.forward(x)
    return logits, (N, C, H, W)