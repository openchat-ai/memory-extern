"""合体探针: 反量化 Q4T 的一层 FFN, 验证可逆(§11.1), 为外积注入做准备."""
import sys, numpy as np
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, SlimMat, SC_TAB, CB, QK

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
print("bit",eng.bit,"layers",eng.n_layer,"codebook:",eng.cb[:3], "...", eng.cb[-3:])
# 找一个 FFN 张量
names=[n for n in eng.mat if 'ffn' in n]
print("FFN 张量:", names[:6])
n0=names[0]
sm=eng.mat[n0]
print(f"{n0}: n_in={sm.n_in} n_out={sm.n_out} bit={sm.bit} cb={sm.cb[:3] if sm.cb is not None else None}")
# 反量化整个矩阵, 再量化回去, 看误差
x=np.eye(sm.n_in, dtype=np.float32)   # 单位阵 -> y = W^T
Wt=sm._matmul_np(x)                    # (n_in, n_out) = W
print("W shape", Wt.shape, "|W|", np.linalg.norm(Wt), "std", Wt.std())
# 逐块检查: 每 32 个元素一个 scale, 是否可精确表示
print("样例 W[0,:8]:", Wt[0,:8])
