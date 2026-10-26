"""验证: 用 fp32 覆盖层替换 MLP, 前向输出应与原 Q4T 完全一致 (§11.1).

若不一致 -> 覆盖机制有 bug, 后面全部作废.
"""
import sys, numpy as np
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
toks=np.array(eng.encode(prompt),np.int64)

# 基线
base,_=eng.forward(toks)
print("base top3:",[(eng.tok_list[i],round(float(base[i]),3)) for i in base.argsort()[::-1][:3]])

class Fp32Mat:
    """纯 fp32 权重, 提供 .matmul."""
    def __init__(self, W):
        self.W=W.astype(np.float32); self.n_in=W.shape[0]; self.n_out=W.shape[1]
    def matmul(self, x):
        return x @ self.W

LAYER=2
names=["ffn_gate.weight","ffn_up.weight","ffn_down.weight"]
# 反量化原权重 -> 存为 fp32 覆盖
orig={}
for nm in names:
    sm=eng.mat[f"blk.{LAYER}.{nm}"]
    W=sm._matmul_np(np.eye(sm.n_in,dtype=np.float32))
    orig[nm]=(sm, W)
    eng.mat[f"blk.{LAYER}.{nm}"]=Fp32Mat(W)
print("已替换 layer",LAYER,"的 MLP 为 fp32 覆盖")

cov,_=eng.forward(toks)
print("覆盖后 top3:",[(eng.tok_list[i],round(float(cov[i]),3)) for i in cov.argsort()[::-1][:3]])
diff=np.abs(cov-base).max()
print(f"与基线最大 logit 差: {diff:.6f}  相对 {diff/np.abs(base).max():.2e}")
print("结论:", "一致 ✓" if diff < 0.5 else "不一致 ✗ 有bug")
