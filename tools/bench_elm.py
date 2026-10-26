"""§10.38 随机特征 + 闭式读出 (ELM / 广义赫布) 能否从零做语言模型?

冻结随机初始化的全部权重, 只用岭回归(最小二乘)拟合读出层, 与已跑过的
梯度训练基线比 CE. 配置与基线一致: V=2400, L=4 d=64 ffn=256.

用法: taskset -c 7 python tools/bench_elm.py
"""
import sys
import os
import time
import math

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from qxn_train import QxN
from a3_pretrain import compress_vocab

T = "/data/data/com.termux/files/usr/tmp/opencode"
BLK, VC, CH = 32, 2400, 32
N_FIT = 512 * 1024
GRAD_CE, GRAD_TOP1 = 3.4054, 37.9

t_load = time.time()
ids = np.load(T + "/codeonly_full.npz")["ids"]
seq, V, _ = compress_vocab(ids, VC)
fit = seq[:N_FIT]
ho = seq[int(len(seq) * 0.95): int(len(seq) * 0.95) + 64 * 1024]
print(f"[data] {len(seq)/1e6:.2f}M tokens, V={V}, fit={len(fit)}, eval={len(ho)}"
      f"  ({time.time()-t_load:.1f}s)", flush=True)

model = QxN(4, 64, 4, 256, V, BLK, mode="fp32", seed=0)
NP = sum(v.size for v in model.P.values())
print(f"[model] {NP/1e6:.2f}M params, 随机初始化并冻结", flush=True)
D = (1 + model.n_layer) * model.n_embd


def feats(x):
    _, caches, xf, _, _ = model.forward(x, collect=True)
    return np.concatenate([xf] + [caches[i]["x"] for i in range(model.n_layer)], -1)


def batches(tokens):
    n = (len(tokens) // (CH * BLK)) * CH * BLK
    return tokens[:n].reshape(-1, CH, BLK)


def nll(logits, tgt):
    m = logits.max(1, keepdims=True)
    lse = m[:, 0] + np.log(np.exp(logits - m).sum(1))
    return (lse - logits[np.arange(len(tgt)), tgt]), (logits.argmax(1) == tgt)


def eval_ridge(W, tokens):
    tot, n, ok = 0.0, 0, 0
    for xb in batches(tokens):
        F = feats(xb)
        H = F[:, :-1].reshape(-1, D)
        Hb = np.concatenate([H, np.ones((len(H), 1), np.float32)], 1)
        tgt = xb[:, 1:].reshape(-1)
        a, b = nll(Hb @ W, tgt)
        tot += a.sum(); ok += b.sum(); n += len(tgt)
    return tot / n, ok / n


def eval_random(tokens):
    tot, n, ok = 0.0, 0, 0
    for xb in batches(tokens):
        lg = model.forward(xb)[:, :-1].reshape(-1, V)
        tgt = xb[:, 1:].reshape(-1)
        a, b = nll(lg, tgt)
        tot += a.sum(); ok += b.sum(); n += len(tgt)
    return tot / n, ok / n


G = np.zeros((D + 1, D + 1))
R = np.zeros((D + 1, V))
G1 = np.zeros((model.n_embd + 1, model.n_embd + 1))
R1 = np.zeros((model.n_embd + 1, V))
cnt = np.zeros(V)
t0 = time.time()
nb = 0
for xb in batches(fit):
    F = feats(xb)
    H = F[:, :-1].reshape(-1, D)
    tgt = xb[:, 1:].reshape(-1)
    Y = np.zeros((len(tgt), V), np.float32)
    Y[np.arange(len(tgt)), tgt] = 1
    Hb = np.concatenate([H, np.ones((len(H), 1), np.float32)], 1)
    H1 = F[:, :-1, :model.n_embd].reshape(-1, model.n_embd)
    Hb1 = np.concatenate([H1, np.ones((len(H1), 1), np.float32)], 1)
    G += Hb.T @ Hb
    R += Hb.T @ Y
    G1 += Hb1.T @ Hb1
    R1 += Hb1.T @ Y
    cnt += np.bincount(tgt, minlength=V)
    nb += 1
    if nb % 50 == 0:
        print(f"  fit {nb*CH*BLK}/{len(fit)}  {time.time()-t0:.0f}s", flush=True)
print(f"[fit] {nb} 块 {time.time()-t0:.0f}s", flush=True)

ce_r, t1_r = eval_random(ho)
pu = (cnt + 1) / (cnt.sum() + V)
tgt_all = []
tot_u = 0.0
n_u = 0
for xb in batches(ho):
    tg = xb[:, 1:].reshape(-1)
    tot_u += (-np.log(pu[tg])).sum(); n_u += len(tg)
print(f"[对照] 随机权重 CE {ce_r:.4f} top1 {t1_r*100:.1f}%  |  unigram CE {tot_u/n_u:.4f}"
      f"  |  梯度训练基线 CE {GRAD_CE:.4f} top1 {GRAD_TOP1:.1f}%", flush=True)

scale = np.trace(G) / len(G)
best_all = None
for lam in (1e-4, 1e-3, 1e-2, 1e-1):
    W = np.linalg.solve(G + lam * scale * np.eye(len(G)), R)
    c, t1 = eval_ridge(W, ho)
    print(f"[multi-layer d={D}] λ={lam:g}  CE {c:.4f}  ppl {math.exp(min(20,c)):7.2f}"
          f"  top1 {t1*100:.1f}%", flush=True)
    if best_all is None or c < best_all[0]:
        best_all = (c, t1, lam)
scale1 = np.trace(G1) / len(G1)
best_1 = None
for lam in (1e-4, 1e-3, 1e-2, 1e-1):
    W = np.linalg.solve(G1 + lam * scale1 * np.eye(len(G1)), R1)
    tot, n, ok = 0.0, 0, 0
    for xb in batches(ho):
        F = feats(xb)
        Hf = F[:, :-1, :model.n_embd].reshape(-1, model.n_embd)
        Hb = np.concatenate([Hf, np.ones((len(Hf), 1), np.float32)], 1)
        tg = xb[:, 1:].reshape(-1)
        a, b = nll(Hb @ W, tg)
        tot += a.sum(); ok += b.sum(); n += len(tg)
    c, t1 = tot / n, ok / n
    print(f"[final-hidden d={model.n_embd}] λ={lam:g}  CE {c:.4f}  ppl {math.exp(min(20,c)):7.2f}"
          f"  top1 {t1*100:.1f}%", flush=True)
    if best_1 is None or c < best_1[0]:
        best_1 = (c, t1, lam)

print(f"\n最好: multi-layer CE {best_all[0]:.4f} | final-hidden CE {best_1[0]:.4f}"
      f" | 梯度基线 {GRAD_CE:.4f}", flush=True)
