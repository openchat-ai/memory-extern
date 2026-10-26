"""机制验证: 直接给 W2 加一个外积 Δ, 看 ffn 输出与最终 top-1 是否移动.
不做"正确注入", 只要证明 ΔW2 -> logits 的通路是活的."""
import numpy as np, sys
sys.path.insert(0, 'tools')
from qxn_train import build_from_ckpt, wv

model, cfg = build_from_ckpt(dict(np.load('ckpt_fp32.npz')), mode='fp32', strict=True)
toks = np.array([[1,2,3,4,5,6,7,8]], np.int64)

base = model.forward(toks)
print("baseline top1:", base[0,-1].argmax(), "logits[0,-1] var", base[0,-1].std())

# 取第0层 ffn 输入
_, caches, _, _, _ = model.forward(toks, collect=True)
hh = caches[0]['hh'].reshape(-1, model.n_embd)     # (8, 192)
from qxn_train import gelu
W1,W3 = model.P['l0.w1'], model.P['l0.w3']
phi = gelu(hh@W1) * (hh@W3)                        # (8, 384) ffn_mid

# 随机目标 token
target = 1234
# 构造 ΔW2 = c * (Wo[:,target] 方向) 外积 phi, 使 target 的 logit 提升
# 最终 logits = ff@Wo,  ff = phi@W2.  要 d logits[:,target] = ff_delta@Wo[:,target]
Wo = wv(model,'out')                                # (192,18540)
v_dir = Wo[:, target]                               # (192,) , d=192
# 想让 W2 行的组合... 直接: Δff = alpha * v_dir (形状 192), 那 logits target 增 alpha*|v_dir|^2
# Δff = phi @ ΔW2  => 需要 ΔW2 = (1/|phi|^2) * phi^T @ Δff^T ... 取单 key 精确:
k = phi[3]                                          # 用第3个位置作 key (384,)
alpha = 5.0
Delta_ff = alpha * v_dir                            # (192,)
dW2 = np.outer(k, Delta_ff) / (k@k)                 # (384,192)  rank-1
print("dW2 shape", dW2.shape, "|dW2|", np.linalg.norm(dW2))

model.P['l0.w2'] = (model.P['l0.w2'] + dW2).astype(np.float32)
after = model.forward(toks)
print("after   top1:", after[0,-1].argmax(), "  target logit:",
      base[0,-1,target], "->", after[0,-1,target])
print("在该位置 (idx3) 下一 token 是否更接近 target? 前后 top1@3:",
      base[0,3].argmax(), "->", after[0,3].argmax(), "target=",target)
