"""变体验证: 保留原层 A,G (=Q4T gate/up), 只把 B(=down) 换成外积构造.
B 输出维 = d = 1024 (隐状态空间). 事实: 输入某 token -> 输出推向"能产生 target token"的隐状态.

但 B 输出是隐状态, 不是 logits. 如何构造 v (隐状态方向)?
近似: 用 embd[target] 作为"希望下游产生 target"的隐状态代理 —— 这是粗糙近似.
先验证机制 (通路), 不追求正确 (§11.1)."""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope, q8_gemm_proj

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
toks=np.array(eng.encode(prompt),np.int64)
tgt=eng.tok_to_id["print"]

class Fp32Mat:
    def __init__(self, W):
        self.W=W.astype(np.float32); self.n_in=W.shape[0]; self.n_out=W.shape[1]
    def matmul(self, x): return x @ self.W

LAYER=2
# 抓该层 phi (即 ffn_down 的输入), 和 h (ffn 输入)
def capture(layer,toks):
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
        if i==layer: res=(phi.copy(),h.copy(),x.copy())
        x=x+M[p+"ffn_down.weight"].matmul(phi)
    return res

phi,h,xbefore=capture(LAYER,toks)
print(f"layer{LAYER}: phi {phi.shape}, 末位 phi[-1] norm {np.linalg.norm(phi[-1]):.3f}")

# 原 B (down): 3072 -> 1024
B_orig=eng.mat[f"blk.{LAYER}.ffn_down.weight"]._matmul_np(np.eye(3072,dtype=np.float32))
print("B_orig", B_orig.shape, "|B|", np.linalg.norm(B_orig))

# 变体: B_new = B_orig + c * v ⊗ phi_key  (在末位写入)
# v 取 embd[target] 近似 (隐状态方向代理)
# 但 embd 不直接暴露; 用末投影的逆? 用 Q8_0 embd. 
# 简化: 先用随机 v 验证"写入能否改变 logit" (通路)
rng=np.random.default_rng(0)
def fwd_with_B(Bnew):
    eng.mat[f"blk.{LAYER}.ffn_down.weight"]=Fp32Mat(Bnew)
    lo,_=eng.forward(toks)
    orig=eng.mat[f"blk.{LAYER}.ffn_down.weight"]
    return lo

base,_=eng.forward(toks)
print("base target logit %.3f top1 %r"%(base[tgt],eng.tok_list[int(base.argmax())]))

phik=phi[-1].astype(np.float64)
for c in (0.1,1.0,10.0):
    v=rng.standard_normal(1024)
    dB=c*np.outer(phik,v)/(phik@phik)
    lo=fwd_with_B(B_orig+dB.astype(np.float32))
    print(f"  c={c:5} target logit {lo[tgt]:8.3f} top1 {eng.tok_list[int(lo.argmax())]!r}")
