"""Q4T 的 attn 权重 vs 源 Q8_0 的 attn 权重, 相对误差 (§11.2)."""
import sys, numpy as np, struct
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC

def read_q8_tensor(path, name):
    """从 GGUF 读一个 Q8_0 张量并反量化."""
    import gguf  # 若没有则手写
    pass

# 先看有没有 gguf 库
try:
    import gguf
    HAVE=True
except ImportError:
    HAVE=False
print("gguf lib:", HAVE)

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)

# 用 q1t_stream 里的 GGUF reader 读源 Q8_0 的 attn_q
print("SRC:", SRC)
# 看引擎有没有暴露读源张量的函数
import q1t_stream as q
print("模块函数:", [a for a in dir(q) if 'read' in a.lower() or 'gguf' in a.lower() or 'load' in a.lower()])
