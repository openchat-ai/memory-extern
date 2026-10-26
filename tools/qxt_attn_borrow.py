"""对照: 借 Q4T vs 借 Q8_0 的 attention, 输出差多少? (§11.2 定位到部件)
用同一 prompt, 分别用 packslim(Q4T) 引擎 和 源 Q8_0 跑, 比较最后一层 attn 输出."""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope
import inspect

# 看引擎里 attn 权重是怎么来的: SlimMat 从 packslim 读
# 先确认 Q4T 引擎的 attn 权重和 Q8_0 源的关系
slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
print("slim:", eng.slim)
print("src :", eng.src)
print("bit :", eng.bit)
# attn_q 的形状和来源
sm=eng.mat["blk.0.attn_q.weight"]
print("blk.0.attn_q: n_in",sm.n_in,"n_out",sm.n_out)
print("SlimMat 属性:", [a for a in dir(sm) if not a.startswith('__')][:15])
# 反量化一个 attn 权重, 和源 Q8_0 对比
W_q4t=sm._matmul_np(np.eye(sm.n_in,dtype=np.float32))
print("Q4T attn_q |W| =", np.linalg.norm(W_q4t))
