"""验证 value 方向: 最后一层 down 输出 + c*embd[target], 目标 logit 是否升 (§11.1)."""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
toks=np.array(eng.encode(prompt),np.int64)
tgt=eng.tok_to_id["print"]

class Fp32Mat:
    def __init__(self,W): self.W=W.astype(np.float32); self.n_in=W.shape[0]; self.n_out=W.shape[1]
    def matmul(self,x): return x@self.W

# 最后一层 down 输出 = x_last_ffn 贡献. 直接给该层 down 加 right-add:
# 在 down 输出上加 delta: y = phi @ B;  想让 y += delta, 需 B += outer(pinv(phi), delta)
# 用单点: phi 是 (T,3072). 我们只控末位.
LAST=eng.n_layer-1   # blk.27

# 取 embd[target] 作为 delta 方向
emb_t=eng._embed([tgt])[0]   # (1024,)
print("embd[target] norm", np.linalg.norm(emb_t))

# 抓最后一层 phi
def capture_phi(layer,toks):
    M=eng.mat; x=eng._embed(list(toks)); T=len(toks)
    nh,nkv,hd=eng.n_head,eng.n_kv,eng.hd; rep=nh//nkv
    cos,sin=eng.cos[:T],eng.sin[:T]; res=None
    for i in range(eng.n_layer):
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
        if i==layer: res=phi.copy()
        x=x+M[p+"ffn_down.weight"].matmul(phi)
    return res

phi=capture_phi(LAST,toks)
B_orig=eng.mat[f"blk.{LAST}.ffn_down.weight"]._matmul_np(np.eye(3072,dtype=np.float32))
phik=phi[-1].astype(np.float64)
base,_=eng.forward(toks)
print(f"base target logit {base[tgt]:.3f} top1 {eng.tok_list[int(base.argmax())]!r}")

# 在末位 down 输出加 c*embd[target]:  B += outer(phik, c*emb_t)/(phik@phik)
for c in (0.5,1.0,2.0,5.0,10.0):
    delta=c*emb_t.astype(np.float64)
    dB=np.outer(phik,delta)/(phik@phik)
    eng.mat[f"blk.{LAST}.ffn_down.weight"]=Fp32Mat(B_orig+dB.astype(np.float32))
    lo,_=eng.forward(toks)
    print(f"  c={c:5} target logit {lo[tgt]:8.3f} rank {int((lo>lo[tgt]).sum()):5d} top1 {eng.tok_list[int(lo.argmax())]!r}")
