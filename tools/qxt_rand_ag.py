"""甲: 随机 A/G 的 φ 正交性 (§11.1 先验 φ, 不接全模型).

事实 key = 输入隐状态 h (该层 ffn 输入). φ = gelu(h@A) * (h@G).
对比: 
  (a) 训好的 A/G (Q4T 第 k 层)  -> φ 不正交 (已知 +0.347)
  (b) 随机 A/G                -> φ 应准正交 (论文前提)
"""
import sys, numpy as np
sys.path.insert(0,'tools')
from qxt_hebb import HebbInjector, Fp32Mat

FACTS = ["def add(a, b):","def subtract(a, b):","def multiply(a, b):","import math",
         "import os","class Animal:","x = [1, 2, 3]","def main():",
         "from sys import argv","with open('f') as fh:"]

H = HebbInjector()
# 抓每条的 ffn 输入 h (层 LAYER 的 ffn_norm 后) 和原 A/G
LAYER = 5
from q1t_stream import rmsnorm, apply_rope
import math

def capture_h(eng, layer, toks):
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

hs=np.stack([capture_h(H.eng,LAYER,np.array(H.eng.encode(p),np.int64)) for p in FACTS])  # (10,d)
print(f"层{LAYER} ffn 输入 h: {hs.shape}")
d=H.d; F=H.F

def phi_of(hs, A, G):
    x=hs@A; phi=(x/(1+np.exp(-x)))*(hs@G)
    Pn=phi/np.linalg.norm(phi,axis=1,keepdims=True)
    C=Pn@Pn.T; off=C[~np.eye(len(hs),dtype=bool)]
    return off

# (a) 训好的 A/G
A_t=H.eng.mat[f"blk.{LAYER}.ffn_gate.weight"]._matmul_np(np.eye(d,dtype=np.float32))
G_t=H.eng.mat[f"blk.{LAYER}.ffn_up.weight"]._matmul_np(np.eye(d,dtype=np.float32))
off_t=phi_of(hs,A_t,G_t)
print(f"(a) 训好 A/G: φ 非对角余弦 均值 {off_t.mean():+.3f} 最大 {off_t.max():+.3f}")

# (b) 随机 A/G (匹配尺度: 标准差 = 训好的)
gA=np.linalg.norm(A_t)/np.sqrt(d*F); gG=np.linalg.norm(G_t)/np.sqrt(d*F)
for seed in (0,1,2):
    rng=np.random.default_rng(seed)
    A=rng.standard_normal((d,F)).astype(np.float32)*gA
    G=rng.standard_normal((d,F)).astype(np.float32)*gG
    off=phi_of(hs,A,G)
    print(f"(b) 随机 A/G seed{seed}: φ 非对角余弦 均值 {off.mean():+.3f} 最大 {off.max():+.3f} "
          f"|cos|>0.5 {(np.abs(off)>0.5).mean()*100:.0f}%")

# 测 h 本身的相似度 (上游根因)
Hn=hs/np.linalg.norm(hs,axis=1,keepdims=True)
Ch=Hn@Hn.T; offh=Ch[~np.eye(len(hs),dtype=bool)]
print(f"\nh (输入隐状态) 本身: 非对角余弦 均值 {offh.mean():+.3f} 最大 {offh.max():+.3f}")
print(f"  |cos|>0.5: {(np.abs(offh)>0.5).mean()*100:.0f}%   |cos|>0.9: {(np.abs(offh)>0.9).mean()*100:.0f}%")
print("  -> 若 h 本身高度相似, 则任何 A/G (训的或随机的) 都无法分开")
