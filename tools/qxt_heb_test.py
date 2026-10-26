"""Hebbian 闭式注入到 QxT FFN 的 down 矩阵 (W2)。

构造 (论文 φ(x)=g(Ax)⊙(Gx), MLP=B·φ(x)):
    目标: 给定 key 隐状态 k, 输出应为 v
    B 增量: ΔW2 += (1/m) · (v_emb) ⊗ φ(k)     # 外积, φ(k)=g1(k)⊙g3(k) 在中间层
    其中 φ(k) 是 W2 的输入 (ffn_mid), v_emb 是目标 token 的 logits 行.

判据: 注入该 key 后, 模型对邻接位置 argmax == target.
"""
import numpy as np, sys
sys.path.insert(0, 'tools')
from qxn_train import build_from_ckpt, wv, gelu

def ffn_mid(model, hh):
    """给定 ffn 输入 hh (…,D), 返回 φ = g1 ⊙ g3 (…,F) 和 a1,a3."""
    W1, W3 = model.P['l0.w1'], model.P['l0.w3']
    a1 = hh @ wv(model, 'l0.w1')
    a3 = hh @ wv(model, 'l0.w3')
    return gelu(a1) * a3, a1, a3

def build_key_state(model, toks, layer=0):
    """取第 layer 层 ffn 的实际输入 hh (关键: 要拿真实前向产生的, 不是手搓)."""
    logits, caches, xf, x, _oc = model.forward(toks, collect=True)
    c = caches[layer]
    return logits, c['hh']          # hh: (B,T,D)

def inject(model, key_hh, target_id, m=1, layer=0, scale=1.0):
    """ΔW2 += (1/m) scale · onehot(target) ⊗ φ(key). 返回 Δ 的范数."""
    phi, _, _ = ffn_mid(model, key_hh.reshape(-1, key_hh.shape[-1]))
    # phi: (n_keys, F)
    Vd = model.P['out'].shape[1]
    Dv = model.P['l0.w2'].shape[1]          # = n_embd
    Vemb = np.zeros((len(phi), Dv), np.float32)
    Vemb[:, :] = 0
    # 值向量的“反投影”: 我们想让 W2 输出 = 目标 logits 分量, 但 out 是 d->V.
    # 简化: 在 ffn 输出空间直接选一个方向, 使 out 行 target 被抬高.
    # Δout = Δff @ Wo ; 要 out[:,target] 升, 取 Δff 沿 Wo[:,target] 方向.
    Wo = wv(model, 'out')                    # (D, V) 或 (V, D)
    print("   Wo shape:", Wo.shape)
    return phi, Vemb, Wo

for mode in ('fp32', 'bitnet'):
    f = 'ckpt_fp32.npz' if mode == 'fp32' else 'ckpt_bitnet.npz'
    model, cfg = build_from_ckpt(dict(np.load(f)), mode=mode, strict=True)
    print(f"[{mode}] out shape {model.P['out'].shape}, w2 {model.P['l0.w2'].shape}")
    logits, hh = build_key_state(model, np.array([[1,2,3,4,5,6,7,8]], np.int64))
    phi, _, _ = ffn_mid(model, hh.reshape(-1, model.n_embd))
    print(f"   phi {phi.shape}  |phi|={np.linalg.norm(phi,axis=-1)}")
