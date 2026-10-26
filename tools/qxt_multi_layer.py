"""B 方案: 多层 down 同时写入一条事实, 测 logit 增益 vs 层数 (§11.2 定位)."""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
toks=np.array(eng.encode(prompt),np.int64)
tgt=eng.tok_to_id["print"]
N=eng.n_layer
print("n_layer",N)

class Fp32Mat:
    def __init__(self,W): self.W=W.astype(np.float32); self.n_in=W.shape[0]; self.n_out=W.shape[1]
    def matmul(self,x): return x@self.W

def capture_all_phi(toks):
    M=eng.mat; x=eng._embed(list(toks)); T=len(toks)
    nh,nkv,hd=eng.n_head,eng.n_kv,eng.hd; rep=nh//nkv
    cos,sin=eng.cos[:T],eng.sin[:T]; phis={}
    for i in range(N):
        p=f"blk.{i}."
        h=rmsnorm(x,eng.norm[p+"attn_norm.weight"],eng.eps)
        q=M[p+"attn_q.weight"].matmul(h).reshape(-1,nh,hd)
        kk=M[p+"attn_k.weight"].matmul(h).reshape(-1,nkv,hd)
        vv=M[p+"attn_v.weight"].matmul(h).reshape(-1,nkv,hd)
        q=rmsnorm(q,eng.norm[p+"attn_q_norm.weight"],eng.eps)
        kk=rmsnorm(kk,eng.norm[p+"attn_k_norm.weight"],eng.eps)
        q=apply_rope(q,cos,sin,np.arange(T)); kk=apply_rope(kk,cos,sin,np.arange(T))
        ckr=np.repeat(kk,rep,1); cvr=np.repeat(vv,rep,1)
        sc=np.einsum("qhd,khd->hqk",q,ckr)/math.sqrt(hd)
        mask=np.triu(np.ones((T,T),bool),1)[None]
        sc=np.where(mask,-1e9,sc); pr=np.exp(sc-sc.max(-1,keepdims=True)); pr/=pr.sum(-1,keepdims=True)
        o=np.einsum("hqk,khd->qhd",pr,cvr).reshape(-1,nh*hd)
        x=x+M[p+"attn_output.weight"].matmul(o)
        h=rmsnorm(x,eng.norm[p+"ffn_norm.weight"],eng.eps)
        g=M[p+"ffn_gate.weight"].matmul(h); u=M[p+"ffn_up.weight"].matmul(h)
        phi=g/(1+np.exp(-g))*u
        phis[i]=phi[-1].astype(np.float64)   # 末位 phi
        x=x+M[p+"ffn_down.weight"].matmul(phi)
    return phis

phis=capture_all_phi(toks)
emb_t=eng._embed([tgt])[0].astype(np.float64)
B={i:eng.mat[f"blk.{i}.ffn_down.weight"]._matmul_np(np.eye(3072,dtype=np.float32)) for i in range(N)}
base,_=eng.forward(toks)
print(f"base target logit {base[tgt]:.3f} rank {int((base>base[tgt]).sum())} top1 {eng.tok_list[int(base.argmax())]!r}")

def write_layers(layers, c):
    for i in layers:
        pk=phis[i]; dB=np.outer(pk, c*emb_t)/(pk@pk)
        eng.mat[f"blk.{i}.ffn_down.weight"]=Fp32Mat(B[i]+dB.astype(np.float32))
    lo,_=eng.forward(toks)
    for i in layers:   # 恢复
        eng.mat[f"blk.{i}.ffn_down.weight"]=Fp32Mat(B[i])
    return lo

# 测: 最后 k 层, 每层同 c
for k in (1,2,4,8,16,28):
    layers=list(range(N-k,N))
    for c in (5.0,):
        lo=write_layers(layers,c)
        print(f"  最后{k:2d}层 c={c}: target {lo[tgt]:7.3f} rank {int((lo>lo[tgt]).sum()):5d} top1 {eng.tok_list[int(lo.argmax())]!r}")
