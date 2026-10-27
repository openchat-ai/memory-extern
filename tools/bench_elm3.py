"""§10.38c 最后一个口子: logistic(softmax) 读出.

主体仍是冻结的随机权重, 只把读出从"最小二乘"换成"凸的 softmax 回归"
(Adam 从岭回归解热启动). 这是随机特征能拿到的最强线性读出.
若它仍过不了 bigram (4.2969), 则"线性读出 + 随机特征"这一族被彻底排除.

用法: taskset -c 4 python tools/bench_elm3.py
"""
import sys
import os
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qxn_train import QxN
from a3_pretrain import compress_vocab

T = "/data/data/com.termux/files/usr/tmp/opencode"
BLK, VC, CH = 32, 2400, 32
N_FIT, N_VAL, N_TEST = 128 * 1024, 16 * 1024, 32 * 1024
BATCH, EPOCHS, LR = 8192, 60, 3e-3
UNI, BIG, GRAD = 6.1156, 4.2969, 3.4054

ids = np.load(T + "/codeonly_full.npz")["ids"]
seq, V, _ = compress_vocab(ids, VC)
fit = seq[:N_FIT]
val = seq[int(len(seq) * 0.95): int(len(seq) * 0.95) + N_VAL]
test = seq[int(len(seq) * 0.97): int(len(seq) * 0.97) + N_TEST]

model = QxN(4, 64, 4, 256, V, BLK, mode="fp32", seed=0)


def collect(tokens):
    Hs, Ts = [], []
    n = (len(tokens) // (CH * BLK)) * CH * BLK
    for xb in tokens[:n].reshape(-1, CH, BLK):
        _, _, xf, _, _ = model.forward(xb, collect=True)
        Hs.append(xf[:, :-1].reshape(-1, xf.shape[-1]).astype(np.float32))
        Ts.append(xb[:, 1:].reshape(-1))
    H = np.concatenate(Hs)
    return H, np.concatenate(Ts)


t0 = time.time()
Hf, tf = collect(fit)
mu, sd = Hf.mean(0, keepdims=True), Hf.std(0, keepdims=True) + 1e-6
Hf = np.concatenate([(Hf - mu) / sd, np.ones((len(Hf), 1), np.float32)], 1)
Hv, tv = collect(val)
Hv = np.concatenate([(Hv - mu) / sd, np.ones((len(Hv), 1), np.float32)], 1)
Ht, tt = collect(test)
Ht = np.concatenate([(Ht - mu) / sd, np.ones((len(Ht), 1), np.float32)], 1)
D = Hf.shape[1]
print(f"[feat] fit {Hf.shape} val {Hv.shape} test {Ht.shape} D={D} ({time.time()-t0:.0f}s)", flush=True)


def ce(H, tgt, W):
    tot, n, ok = 0.0, 0, 0
    for i in range(0, len(H), 4096):
        lg = H[i:i + 4096] @ W
        m = lg.max(1, keepdims=True)
        lse = m[:, 0] + np.log(np.exp(lg - m).sum(1))
        t = tgt[i:i + 4096]
        tot += float((lse - lg[np.arange(len(t)), t]).sum())
        ok += int((lg.argmax(1) == t).sum())
        n += len(t)
    return tot / n, ok / n


G = Hf.T @ Hf
R = np.zeros((D, V), np.float32)
for i in range(0, len(Hf), 8192):
    Y = np.zeros((min(8192, len(Hf) - i), V), np.float32)
    Y[np.arange(len(Y)), tf[i:i + len(Y)]] = 1
    R += Hf[i:i + len(Y)].T @ Y
del Y
scale = np.trace(G) / D
W = np.linalg.solve(G + 1e-4 * scale * np.eye(D), R).astype(np.float32)
c0, t10 = ce(Hv, tv, W)
print(f"[init ridge] val CE {c0:.4f} top1 {t10*100:.1f}% ({time.time()-t0:.0f}s)", flush=True)

mW = np.zeros_like(W)
vW = np.zeros_like(W)
b1, b2 = 0.9, 0.999
rng = np.random.default_rng(0)
best = (c0, 0, W.copy())
for ep in range(1, EPOCHS + 1):
    idx = rng.permutation(len(Hf))
    tot = 0.0
    for i in range(0, len(idx) - BATCH + 1, BATCH):
        b = idx[i:i + BATCH]
        Hb = Hf[b]
        lg = Hb @ W
        lg -= lg.max(1, keepdims=True)
        p = np.exp(lg)
        p /= p.sum(1, keepdims=True)
        p[np.arange(BATCH), tf[b]] -= 1.0
        gW = Hb.T @ p / BATCH + 1e-4 * W
        mW = b1 * mW + (1 - b1) * gW
        vW = b2 * vW + (1 - b2) * gW * gW
        mh = mW / (1 - b1 ** ep)
        vh = vW / (1 - b2 ** ep)
        W -= LR * mh / (np.sqrt(vh) + 1e-8)
        tot += float((-np.log(np.maximum((Hb @ W)[np.arange(BATCH), tf[b]] * 0 + 1e-9, 1e-9))).mean()) * 0
    c, t1 = ce(Hv, tv, W)
    print(f"  ep{ep:2d} | val CE {c:.4f} top1 {t1*100:.1f}% ({time.time()-t0:.0f}s)", flush=True)
    if c < best[0]:
        best = (c, ep, W.copy())

c, t1 = ce(Ht, tt, best[2])
np.savez("/data/data/com.termux/files/usr/tmp/opencode/elm3_W.npz", W=best[2], mu=mu, sd=sd)
print(f"\n[logistic 读出] val CE {best[0]:.4f} (ep{best[1]}) | test CE {c:.4f} top1 {t1*100:.1f}%")
print(f"[对照] unigram {UNI} | bigram {BIG} | 梯度训练 {GRAD} | 岭回归 7.711")
print("判定: " + ("仍不及 bigram -> 线性读出族排除" if c > BIG else "超过 bigram -> 需要重新审视"))
