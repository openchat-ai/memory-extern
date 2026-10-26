"""用真实编码器 (q4f8._enc_block/encode) 重做增量存活率测试 (§11.1)."""
import sys, numpy as np
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC
import q4f8_codebook as Q4

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
sm=eng.mat['blk.0.ffn_down.weight']
W=sm._matmul_np(np.eye(sm.n_in,dtype=np.float32))    # (3072,1024) 列主序
CB=eng.cb.astype(np.float64)
print("cb",CB[:3],"...",CB[-1],"|W|",np.linalg.norm(W))

def quant(W, cb=CB):
    """按 32 元素/块 (沿 n_in, 即行) 编码 -> 重建."""
    n_in,n_out=W.shape
    blocks=W.reshape(n_in//32,32,n_out).transpose(0,2,1).reshape(-1,32)  # (nblk*out,32)
    sc,codes=Q4.encode(blocks, codebook=cb)
    st=Q4.scale_table()
    out=np.empty_like(blocks,dtype=np.float64)
    for i in range(len(blocks)):
        c=codes[i]; code=np.empty(32,np.int64); code[0::2]=c&15; code[1::2]=c>>4
        out[i]=st[sc[i]]*cb[code]
    return out.reshape(n_in//32,n_out,32).transpose(0,2,1).reshape(n_in,n_out)

Wq0=quant(W)
print("量化往返误差:", np.linalg.norm(Wq0-W)/np.linalg.norm(W), "(应 <<1)")
rng=np.random.default_rng(0)
k=rng.standard_normal(sm.n_in).astype(np.float64)
v=rng.standard_normal(sm.n_out).astype(np.float64)
for a in (0.001,0.01,0.1,1.0):
    dW=a*np.outer(k,v)
    Wq=quant(W+dW)
    surv=np.linalg.norm(Wq-Wq0)/np.linalg.norm(dW)
    print(f"alpha={a:6} |dW|={np.linalg.norm(dW):8.3f} 实际改变={np.linalg.norm(Wq-Wq0):8.3f} 存活率={surv:.3f}")
