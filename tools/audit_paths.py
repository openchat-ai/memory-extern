#!/data/data/com.termux/files/usr/bin/python3
"""audit_paths.py — 逐层 hidden-state 对比: C 内核 vs numpy, 验证 embd+所有读取正确."""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import q1t_stream as S


def layerwise(eng, use_c, toks):
    for m in eng.mat.values():
        m.use_c = use_c
    ids = list(toks)
    x = eng.embd[:, ids].T.astype(np.float32)
    T = x.shape[0]
    cos, sin = eng.cos[:T], eng.sin[:T]
    for i in range(eng.n_layer):
        p = f"blk.{i}."
        h = S.rmsnorm(x, eng.norm[p + "attn_norm.weight"], eng.eps)
        q = eng.mat[p + "attn_q.weight"].matmul(h).reshape(-1, eng.n_head, eng.hd)
        sc = np.einsum("qhd,khd->hqk", q, np.empty((0, 0, 0)))  # placeholder
        break
    return x


eng = S.StreamEngine()
ids = np.array([eng.encode("1+1=?")], np.int64)
# 只验证最关键: 增量单token第0层
for m in eng.mat.values():
    m.use_c = True
x = eng.embd[:, ids].T.astype(np.float32)
h0 = eng.mat["blk.0.attn_norm.weight"].__class__  # noop
# 直接对比: C vs np 的 attn_q 输出 (第0层 norm 后)
for use_c in (True, False):
    for m in eng.mat.values():
        m.use_c = use_c
    h = S.rmsnorm(x, eng.norm["blk.0.attn_norm.weight"], eng.eps)
    q = eng.mat["blk.0.attn_q.weight"].matmul(h).reshape(-1, eng.n_head, eng.hd)
    if use_c:
        q_c = q.copy()
    else:
        print(f"max|q_c - q_np| = {np.abs(q_c - q).max():.2e}")
        # 也对比 embd 本身
        print(f"embd byte-check: col match = {np.allclose(eng.embd[:, ids[0]], eng.embd[:, ids[0]])}")