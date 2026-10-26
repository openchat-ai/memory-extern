"""合体: 正确的外积写入. 用数值梯度找"能让 target logit 升"的 dff 方向 (§11.1).

对某层 down 输出 dff (在该位置的 phi), 目标 logit L[target].
dL/d(dff) 可通过有限差分求. 然后 ΔW2 = c · φ^T ⊗ (dL/d(dff)).
"""
import sys, numpy as np, math
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope

slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"

class InjectedMat:
    def __init__(self, base, dW=None):
        self.base=base; self.dW=dW; self.n_in=base.n_in; self.n_out=base.n_out
    def matmul(self, x):
        y=self.base.matmul(x)
        if self.dW is not None: y=y+x@self.dW
        return y

eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
prompt="def add(a, b):"
toks=np.array(eng.encode(prompt),np.int64)
tgt=eng.tok_to_id["print"]
LAYER=5
smkey=f"blk.{LAYER}.ffn_down.weight"
orig=eng.mat[smkey]

def fwd(lo_override=None):
    return eng.forward(toks)[0]

base=fwd()
print("base: target logit %.3f rank %d top1 %r"%(
    base[tgt], int((base>base[tgt]).sum()), eng.tok_list[int(base.argmax())]))

# --- 有限差分求 dL/d(dff) (down 输出在该位置的 3072 维) ---
# dff 影响该位置 x -> 后续层. 用 down 的 ΔW = u ⊗ φ 实现 dff 扰动.
# 数值: 直接对 ΔW 的每一列做?太大. 改: 用随机基向量探梯度方向.
def probe_grad(nprobe=32, eps=1.0, seed=0):
    rng=np.random.default_rng(seed)
    n_in,n_out=orig.n_in,orig.n_out
    g=np.zeros(n_out,np.float64)
    for _ in range(nprobe):
        u=rng.standard_normal(n_out)
        # ΔW: 列方向 u (shape n_in x n_out) 但要在该位置生效需与 phi 耦合.
        # 简化: ΔW = (u/sqrt(n_in)) 广播 → 对 dff 的影响 = phi@ΔW, 与位置耦合.
        # 改用直接法: 给 down 加 ΔW = c * outer(phi[-1]/|phi|^2, u), 则 dff[-1]+=c*u
        # 这里只需要 dL[dff] 的方向, 用 ΔW 实现 dff += eps*u 请见下方 corrector
        pass
    return g

# 直接构造: 要 dff[-1] += delta (n_out 维), 需 ΔW 满足 phi[-1] @ ΔW = delta
# phi[-1] (n_in,), ΔW (n_in,n_out). 取 ΔW = outer(phi[-1], delta)/(phi[-1]@phi[-1])
# 然后 dff 的其他位置也受影响(污染), 但末位置精确可控.
# 抓 phi
def capture_phi(layer,toks):
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
        if i==layer: res=phi.copy()
        x=x+M[pi+"ffn_down.weight"].matmul(phi)
    return res
phi=capture_phi(LAYER,toks)
phik=phi[-1].astype(np.float64)             # (n_in,)
print("phi[-1] |.|", np.linalg.norm(phik))

# 有限差分: 沿随机 delta 方向, 测 dL[target]
n_in,n_out=orig.n_in,orig.n_out
rng=np.random.default_rng(1)
best=None
for trial in range(8):
    delta=rng.standard_normal(n_out).astype(np.float64)
    # dff[-1] += eps*delta  =>  ΔW = outer(phik, eps*delta)/(phik@phik)
    for eps in (0.5, 2.0):
        dW=(np.outer(phik, eps*delta)/(phik@phik)).astype(np.float32)
        inj=InjectedMat(orig,dW)
        eng.mat[smkey]=inj; lo=fwd(); eng.mat[smkey]=orig
        gain=float(lo[tgt]-base[tgt])
        if best is None or abs(gain)>abs(best[0]):
            best=(gain,delta.copy(),eps,trial)
print("最佳随机方向增益: %.3f (trial %d eps %.1f)"%(best[0],best[3],best[2]))

# 用最佳方向做更大步长, 看能否翻 top-1
delta=best[1]
for scale in (1,2,4,8,16):
    dW=(np.outer(phik, scale*delta)/(phik@phik)).astype(np.float32)
    inj=InjectedMat(orig,dW); eng.mat[smkey]=inj
    lo=fwd(); eng.mat[smkey]=orig
    print("  scale=%4d target logit %8.3f (rank %d) top1=%r"%(
        scale, lo[tgt], int((lo>lo[tgt]).sum()), eng.tok_list[int(lo.argmax())]))
