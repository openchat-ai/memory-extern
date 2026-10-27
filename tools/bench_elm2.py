"""§10.38b 检验 7.72 是"随机特征无信息"还是"我的设计坏".

三处改进 + 两个此前缺失的对照:
  1. gain: 投影矩阵整体缩放 (RMSNorm 让输入尺度失效, 真正起作用的是 gain)
  2. z-score 特征 (修最小二乘在相关特征上的不稳定)
  3. 温度校准 (修 one-hot 最小二乘的过度自信) —— 在 val 上拟合, 用到 test
  对照: unigram / bigram (不用模型, 但 bigram 用了上下文)
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
GAINS = (1.0, 2.0, 5.0, 10.0)
PROJ = ("wq", "wk", "wv", "wo", "w1", "w2", "w3")

ids = np.load(T + "/codeonly_full.npz")["ids"]
seq, V, _ = compress_vocab(ids, VC)
fit = seq[:N_FIT]
val = seq[int(len(seq) * 0.95): int(len(seq) * 0.95) + N_VAL]
test = seq[int(len(seq) * 0.97): int(len(seq) * 0.97) + N_TEST]
print(f"[data] fit={len(fit)} val={len(val)} test={len(test)} V={V}", flush=True)


def batches(tokens):
    n = (len(tokens) // (CH * BLK)) * CH * BLK
    return tokens[:n].reshape(-1, CH, BLK)


def collect(model, tokens):
    Hs, Ts = [], []
    for xb in batches(tokens):
        _, caches, xf, _, _ = model.forward(xb, collect=True)
        F = np.concatenate([xf] + [caches[i]["x"] for i in range(model.n_layer)], -1)
        Hs.append(F[:, :-1].reshape(-1, F.shape[-1]).astype(np.float32))
        Ts.append(xb[:, 1:].reshape(-1))
    return np.concatenate(Hs), np.concatenate(Ts)


def ce_chunked(Hb, W, tgt):
    tot, n, ok = 0.0, 0, 0
    for i in range(0, len(Hb), 4096):
        lg = Hb[i:i + 4096] @ W
        m = lg.max(1, keepdims=True)
        lse = m[:, 0] + np.log(np.exp(lg - m).sum(1))
        t = tgt[i:i + 4096]
        tot += float((lse - lg[np.arange(len(t)), t]).sum())
        ok += int((lg.argmax(1) == t).sum())
        n += len(t)
    return tot / n, ok / n


def baselines():
    c = np.bincount(fit, minlength=V).astype(np.float64)
    c[0] = 0
    pu = (c + 1) / (c.sum() + V)
    tot, n = 0.0, 0
    for xb in batches(test):
        b = xb[:, 1:].reshape(-1)
        tot += float((-np.log(pu[b])).sum())
        n += len(b)
    uni = tot / n
    C = np.zeros((V, V), np.float64)
    for i in range(0, len(fit) - 1, 8192):
        a = fit[i:i + 8192].astype(np.int64)
        b = fit[i + 1:i + 1 + 8192].astype(np.int64)
        m = min(len(a), len(b)) - 1
        np.add.at(C, (a[:m], b[:m]), 1.0)
    P = (C + 0.1) / (C.sum(1, keepdims=True) + 0.1 * V)
    tot, n = 0.0, 0
    for xb in batches(test):
        a = xb[:, :-1].reshape(-1).astype(np.int64)
        b = xb[:, 1:].reshape(-1).astype(np.int64)
        tot += float((-np.log(P[a, b])).sum())
        n += len(b)
    return uni, tot / n


uni, big = baselines()
print(f"[对照] unigram CE {uni:.4f} | bigram CE {big:.4f} | 梯度训练基线 3.4054", flush=True)

for g in GAINS:
    model = QxN(4, 64, 4, 256, V, BLK, mode="fp32", seed=0)
    for k in model.P:
        if k.startswith("l") and k.split(".", 1)[-1] in PROJ:
            model.P[k] *= g
    t0 = time.time()
    Hf, tf = collect(model, fit)
    mu, sd = Hf.mean(0, keepdims=True), Hf.std(0, keepdims=True) + 1e-6
    Hb = np.concatenate([(Hf - mu) / sd, np.ones((len(Hf), 1), np.float32)], 1)
    G = Hb.T @ Hb
    R = np.zeros((Hb.shape[1], V), np.float32)
    for i in range(0, len(Hb), 8192):
        Y = np.zeros((min(8192, len(Hb) - i), V), np.float32)
        Y[np.arange(len(Y)), tf[i:i + len(Y)]] = 1
        R += Hb[i:i + len(Y)].T @ Y
    del Hf
    w = np.linalg.eigvalsh(G[:-1, :-1] / len(Hb))
    eff = float((w.sum() ** 2) / (w ** 2).sum())
    Hv, tv = collect(model, val)
    Hvb = np.concatenate([(Hv - mu) / sd, np.ones((len(Hv), 1), np.float32)], 1)
    Ht, tt = collect(model, test)
    Htb = np.concatenate([(Ht - mu) / sd, np.ones((len(Ht), 1), np.float32)], 1)
    del Hv, Ht
    scale = np.trace(G) / len(G)
    best = None
    for lam in (1e-4, 1e-3, 1e-2, 1e-1):
        W = np.linalg.solve(G + lam * scale * np.eye(len(G)), R)
        c, _ = ce_chunked(Hvb, W, tv)
        if best is None or c < best[0]:
            best = (c, lam, W)
    c_raw, lam, W = best
    Ts = np.exp(np.linspace(-2, 4, 61))
    lv = Hvb @ W
    ces = []
    for t in Ts:
        m = (lv / t).max(1, keepdims=True)
        lse = m[:, 0] + np.log(np.exp(lv / t - m).sum(1))
        ces.append(float((lse - (lv / t)[np.arange(len(tv)), tv]).mean()))
    i = int(np.argmin(ces))
    Tb = Ts[i]
    t_raw, top1 = ce_chunked(Htb, W, tt)
    t_cal, _ = ce_chunked(Htb, W / Tb, tt)
    print(f"[gain {g:4.1f}] 有效秩 {eff:5.1f} | λ={lam:g} | val {c_raw:.3f} -> T={Tb:.2f} {ces[i]:.3f}"
          f" | test {t_raw:.3f} -> {t_cal:.3f} | top1 {top1*100:.1f}% ({time.time()-t0:.0f}s)", flush=True)
    del model, Hb, G, R, Hvb, Htb, W
