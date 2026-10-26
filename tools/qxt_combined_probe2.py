"""核心问题: 4-bit 量化下, 外积增量能否存活?
量化: 每 32 元素一块, W_q = d*codebook[code], d=SC_TAB[scale]"""
import sys, numpy as np
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, SC_TAB, CB, QK

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
sm=eng.mat['blk.0.ffn_down.weight']
W=sm._matmul_np(np.eye(sm.n_in,dtype=np.float32))   # 反量化 (3072,1024)

def quant(W, cb):
    """模拟打包: 每32个连续元素(沿 n_in)一块, 块内 max-abs -> scale, 元素->最近码字."""
    n_in,n_out=W.shape
    Wb=W.reshape(n_in//QK, QK, n_out).transpose(0,2,1)  # (nblk, n_out, 32)
    amax=np.abs(Wb).max(-1)                               # (nblk,n_out)
    d=amax/0.95067835                                     # 对标 cb 端点
    norm_abs = np.abs(Wb / (d[..., None] + 1e-12))       # (nblk,n_out,32)
    code = np.argmin(np.abs(norm_abs[:, :, :, None] - cb), axis=-1)
    cbq=cb[code]*d[...,None]
    return cbq.transpose(0,2,1).reshape(n_in,n_out)

Wq0=quant(W, CB)
print("量化往返误差:", np.linalg.norm(Wq0-W)/np.linalg.norm(W))
# 加外积增量
rng=np.random.default_rng(0)
k=rng.standard_normal(sm.n_in).astype(np.float32)      # 假 key (n_in)
v=rng.standard_normal(sm.n_out).astype(np.float32)     # 假 value (n_out)
for alpha in (0.01,0.1,1.0):
    dW=alpha*np.outer(k,v)                              # (n_in,n_out)
    W_new=W+dW
    Wq=quant(W_new, CB)
    survived=np.linalg.norm(Wq-Wq0)/np.linalg.norm(dW)  # 增量存活率
    print(f"alpha={alpha:5} |dW|={np.linalg.norm(dW):7.3f} "
          f"量化后实际改变={np.linalg.norm(Wq-Wq0):7.3f} 存活率={survived:.3f}")
