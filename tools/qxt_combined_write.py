"""合体: 往 Q4T 的某层 ffn_down 写入事实, 端到端验证.

设计:
  - 事实: (key_context -> next_token). key 的 φ = silu(gate(h))⊙up(h) 在该层
  - 写入: ΔW2 += c · φ_key ⊗ v_target,  v_target 取能让 target token logit 抬升的方向
  - 实现: 给 SlimMat 打补丁 —— 前向时叠加 x@ΔW2, 不改文件
  - 判据(§10.1): top-1 是否变成 target; 对照: 不写入
"""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"

class InjectedMat:
    """包一层 SlimMat, 前向 y = x@W + x@dW."""
    def __init__(self, base, dW=None):
        self.base=base; self.dW=dW; self.n_in=base.n_in; self.n_out=base.n_out
    def matmul(self, x):
        y=self.base.matmul(x)
        if self.dW is not None:
            y=y+x@self.dW
        return y

def capture_phi(eng, layer, toks):
    """跑一次前向, 抓该层 ffn 的 φ = silu(gate(h))*up(h) 和 h."""
    from q1t_stream import rmsnorm
    M=eng.mat; p=f"blk.{layer}."
    x=eng._embed(list(toks))
    T=len(toks); nh,nkv,hd=eng.n_head,eng.n_kv,eng.hd; rep=nh//nkv
    cos,sin=eng.cos[:T],eng.sin[:T]
    phis=None
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
        if i==layer: phis=(phi, h.copy())
        x=x+M[pi+"ffn_down.weight"].matmul(phi)
    return phis

eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
toks=np.array(eng.encode(prompt),np.int64)
logits,cache=eng.forward(toks)
print("base top5:",[(eng.tok_list[i],round(float(logits[i]),2)) for i in logits.argsort()[::-1][:5]])

LAYER=5
phi,h=capture_phi(eng,LAYER,toks)
print(f"layer{LAYER} phi shape {phi.shape}, h {h.shape}")

# 目标: 让最后一个位置预测某个 token
target_id=eng.tok_to_id.get("print")
print("target token 'print' id:",target_id)

# value 方向: 使 logits[target] 抬升. 末投影近似: dlogit ≈ dff @ embd[target]  (x 后经 output_norm)
# 但中间还有若干层. 简化? 先做"直接抬升"的近似, 用足够大的幅度
# 更稳: 直接用 embd[target] 作为 dff 想产生的方向, 再乘幅度
emb_t=eng.embd[target_id] if eng.embd is not None else None
print("embd available:", emb_t is not None)
