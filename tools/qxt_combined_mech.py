"""合体机制验证: 往某层 ffn_down 加 Δ, 看能否改变最终 logits (top-1).
不做"正确写入", 先证通路 (§11.1). 对标定: 试不同方向的 Δ, 观察 target logit 增益."""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope, q8_gemm_proj

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"

class InjectedMat:
    def __init__(self, base, dW=None):
        self.base=base; self.dW=dW
        self.n_in=base.n_in; self.n_out=base.n_out
    def matmul(self, x):
        y=self.base.matmul(x)
        if self.dW is not None: y=y+x@self.dW
        return y

eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
ids=eng.encode(prompt)
toks=np.array(ids,np.int64)
logits,_=eng.forward(toks)
tgt=eng.tok_to_id["print"]
print("base top5:",[(eng.tok_list[i],round(float(logits[i]),2)) for i in logits.argsort()[::-1][:5]])
print("target 'print' logit:", float(logits[tgt]), " rank:",
      int((logits>logits[tgt]).sum()))

# 抓 layer5 的 phi 形状 (down 的输入)
LAYER=5
# 重新实现 capture (避免 import 副作用)
def capture_phi(eng, layer, toks):
    M=eng.mat; x=eng._embed(list(toks))
    T=len(toks); nh,nkv,hd=eng.n_head,eng.n_kv,eng.hd; rep=nh//nkv
    cos,sin=eng.cos[:T],eng.sin[:T]; res=None
    for i in range(eng.n_layer):
        pi=f"blk.{i}."
        h=rmsnorm(x,eng.norm[pi+"attn_norm.weight"],eng.eps)
        q=M[pi+"attn_q.weight"].matmul(h).reshape(-1,nh,hd)
        kk=M[pi+"attn_k.weight"].matmul(h).reshape(-1,nkv,hd)
        vv=M[pi+"attn_v.weight"].matmul(h).reshape(-1,nkv,hd)
        q=rmsnorm(q,eng.norm[pi+"attn_q_norm.weight"],eng.eps)
        kk=rmsnorm(kk,eng.norm[pi+"attn_k_norm.weight"],eng.eps)
        q=apply_rope(q,cos,sin,np.arange(T)); kk=apply_rope(kk,cos,sin,np.arange(T))
        ckr=np.repeat(kk,rep,1); cvr=np.repeat(vv,rep,1)
        sc=np.einsum("qhd,khd->hqk",q,ckr)/math.sqrt(hd)
        mask=np.triu(np.ones((T,T),bool),1)[None]
        sc=np.where(mask,-1e9,sc); pr=np.exp(sc-sc.max(-1,keepdims=True)); pr/=pr.sum(-1,keepdims=True)
        o=np.einsum("hqk,khd->qhd",pr,cvr).reshape(-1,nh*hd)
        x=x+M[pi+"attn_output.weight"].matmul(o)
        h=rmsnorm(x,eng.norm[pi+"ffn_norm.weight"],eng.eps)
        g=M[pi+"ffn_gate.weight"].matmul(h); u=M[pi+"ffn_up.weight"].matmul(h)
        phi=g/(1+np.exp(-g))*u
        if i==layer: res=(phi.copy(),h.copy())
        x=x+M[pi+"ffn_down.weight"].matmul(phi)
    return res
phi,h=capture_phi(eng,LAYER,toks)
print(f"layer{LAYER}: phi {phi.shape} (down 输入, n_in={eng.mat[f'blk.{LAYER}.ffn_down.weight'].n_in})")

# 关键: 直接给 down 的 Δ 加"随机方向", 看 target logit 移动幅度 (标定灵敏度)
sm=eng.mat[f"blk.{LAYER}.ffn_down.weight"]
rng=np.random.default_rng(0)
for scale in (0.1,1.0,10.0,100.0):
    dW=scale*rng.standard_normal((sm.n_in,sm.n_out)).astype(np.float32)
    sm_inj=InjectedMat(sm,dW)
    orig=eng.mat[f"blk.{LAYER}.ffn_down.weight"]
    eng.mat[f"blk.{LAYER}.ffn_down.weight"]=sm_inj
    lo,_=eng.forward(toks)
    eng.mat[f"blk.{LAYER}.ffn_down.weight"]=orig
    print(f"  scale={scale:6} |dW|={np.linalg.norm(dW):9.2f} target logit {float(lo[tgt]):8.3f} "
          f"top1={eng.tok_list[int(lo.argmax())]!r}")
