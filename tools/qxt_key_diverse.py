"""修正验证: 语义差异大的 key, h 是否分开? (§11.8 对照验证测量有区分力)"""
import sys, numpy as np
sys.path.insert(0,'tools')
from qxt_hebb import HebbInjector
from q1t_stream import rmsnorm, apply_rope
import math

H=HebbInjector(); d=H.d
LAYER=5
def capture_h(eng,layer,toks):
    M=eng.mat; x=eng._embed(list(toks)); T=len(toks)
    nh,nkv,hd=eng.n_head,eng.n_kv,eng.hd; rep=nh//nkv
    cos,sin=eng.cos[:T],eng.sin[:T]
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
        if i==layer: return h[-1].astype(np.float64)
        g=M[p+"ffn_gate.weight"].matmul(h); u=M[p+"ffn_up.weight"].matmul(h)
        x=x+M[p+"ffn_down.weight"].matmul(g/(1+np.exp(-g))*u)

GROUPS={
 "模板相同(def xxx)": ["def add(a, b):","def subtract(a, b):","def multiply(a, b):","def divide(a, b):","def main():"],
 "语义各异":         ["The capital of France","import numpy as np","class Animal:","x = [1, 2, 3]","while True:"],
 "完全不同的领域":    ["The quick brown fox","SELECT * FROM users","SELECT * FROM orders","Hello world!","1234567890"],
}
for name,ps in GROUPS.items():
    hs=np.stack([capture_h(H.eng,LAYER,np.array(H.eng.encode(p),np.int64)) for p in ps])
    Hn=hs/np.linalg.norm(hs,axis=1,keepdims=True); C=Hn@Hn.T
    off=C[~np.eye(len(ps),dtype=bool)]
    print(f"{name:20s}: h 非对角余弦 均值 {off.mean():+.3f} |cos|>0.5 {(np.abs(off)>0.5).mean()*100:.0f}%")
