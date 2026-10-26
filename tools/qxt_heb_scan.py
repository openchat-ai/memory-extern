"""Hebbian 外积注入 N 条事实到 QxT 的 W2 (FFN down). fp32 vs bitnet 两臂.

论文构造 (φ(x)=g(Ax)⊙(Gx), MLP=B·φ(x)) 映射到 QxT:
    A=W1, G=W3, B=W2, φ=ffn_mid
    ΔW2 = (1/N) Σ_i phi(key_i)^T ⊗ v_i  (秩-1 外积, 平均)

value 方向: 为使最终 logits[target] 抬高, 取 v_i ∝ Wo[:,target_i].
判据: 注入后对每个 key 段末位, argmax==target_i 的命中率.

代价校准 (先量后算, §11.5): |W2|=5.30. alpha 控制 |ΔW2|/|W2|.
"""
import numpy as np, sys
sys.path.insert(0, 'tools')
from qxn_train import build_from_ckpt, wv, gelu

rng = np.random.default_rng(0)
V, D, F, BLK = 18540, 192, 384, 64
SEG = 16


def make_keys(model, N):
    """N 个随机 key 段, 返回各自末位的 ffn 输入 hh (N,D) 和整段 tokens.
    posembd 上限 BLK, 故按 max(N*SEG) 切分成 batch."""
    per = max(1, BLK // SEG)
    key_hh, all_toks = [], []
    done = 0
    while done < N:
        m = min(per, N - done)
        toks = rng.integers(0, V, size=(1, m * SEG), dtype=np.int64)
        _, caches, _, _, _ = model.forward(toks, collect=True)
        hh = caches[0]['hh'][0]                       # (m*SEG, D)
        key_hh.append(hh[np.arange(1, m + 1) * SEG - 1])
        all_toks.append(toks)
        done += m
    return all_toks, np.concatenate(key_hh)


def phi_of(model, key_hh):
    a1 = key_hh @ model.P['l0.w1']
    a3 = key_hh @ model.P['l0.w3']
    return gelu(a1) * a3                              # (N,F)


def eval_hit(model, all_toks, key_pos, tgts):
    pred = []
    for toks in all_toks:
        out = model.forward(toks)
        pred.append(out[0, key_pos[:out.shape[1] // SEG * 0] or None]
                    if False else out[0, np.arange(1, toks.shape[1] // SEG + 1) * SEG - 1])
    pred = np.concatenate([p.argmax(-1) for p in pred])
    return int((pred == tgts).sum()), len(pred)


def run(mode, N, frac=0.10):
    f = 'ckpt_fp32.npz' if mode == 'fp32' else 'ckpt_bitnet.npz'
    model, _ = build_from_ckpt(dict(np.load(f)), mode=mode, strict=True)
    W2o = model.P['l0.w2'].copy()
    all_toks, key_hh = make_keys(model, N)
    phi = phi_of(model, key_hh)                       # (N,F)
    tgts = rng.integers(0, V, size=N)
    Wo = wv(model, 'out')                             # (D,V)
    Vdir = Wo[:, tgts].T                              # (N,D)
    Vdir = Vdir / (np.linalg.norm(Vdir, axis=1, keepdims=True) + 1e-9)
    # 目标幅度: |ΔW2| = frac * |W2|
    raw = (phi.T @ Vdir)                              # (F,D) 未归一
    scale = frac * np.linalg.norm(W2o) / (np.linalg.norm(raw) / N + 1e-12) / N
    dW2 = scale * raw
    model.P['l0.w2'] = (W2o + dW2).astype(np.float32)
    hit_a, _ = eval_hit(model, all_toks, None, tgts)
    model.P['l0.w2'] = W2o
    hit_b, _ = eval_hit(model, all_toks, None, tgts)
    return hit_a, hit_b, N, np.linalg.norm(dW2), np.linalg.norm(W2o)


if __name__ == '__main__':
    print(f"{'mode':7} {'N':>5} {'hit':>9} {'base':>9} {'|dW2|':>8} {'|W2|':>7}")
    for mode in ('fp32', 'bitnet'):
        for N in (1, 5, 20, 50):
            ha, hb, n, dn, w2 = run(mode, N)
            print(f"{mode:7} {n:5d} {ha:4d}/{n:<4d} {hb:4d}/{n:<4d} {dn:8.3f} {w2:7.3f}")
