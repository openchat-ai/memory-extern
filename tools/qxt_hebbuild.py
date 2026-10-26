"""用论文赫布外积「零训练」构造一个 QxN, 让 FFN 成为唯一事实载体.

设计 (对齐论文 φ(x)=g(Ax)⊙(Gx), MLP=B·φ(x)):
  - 事实: N 条 (key_id -> val_id), key/val 都是 "token"
  - 输入: 单 token 序列 [key_id], 取该位置隐状态 = embd[key_id]
  - FFN: A=W1(随机高斯), G=W3(随机高斯), B=W2=(1/N)Σ v⊗φ(k)  ← 外积构造
  - 输出头 out: 只做 φ@W2 ... 但要让它成为 logits, 令 out = 单位(即 W2 输出直接是 logits)
    => 直接把 W2 的形状做成 (F, V), φ 的 value 直接用 onehot(val)
判据: held-out key 的 argmax == val. 对照: 随机 W2 应≈随机.
"""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import gelu

def build(N, D, F, V, seed=0, noise=0.0):
    rng=np.random.default_rng(seed)
    keys=rng.integers(0, V, size=N)          # 事实的 key token
    vals=rng.integers(0, V, size=N)          # 事实的 val token
    A=rng.standard_normal((D,F)).astype(np.float32)
    G=rng.standard_normal((D,F)).astype(np.float32)
    # key 隐状态 = embd[key]: 一个随机 (V,D) 嵌入矩阵 (论文里 A/G 随机, 同理)
    embd=rng.standard_normal((V,D)).astype(np.float32)*0.1
    K=embd[keys]                              # (N,D)
    phi=gelu(K@A)*(K@G)                       # (N,F)
    # B: 使 phi@B ≈ onehot(val), 用 (1/N)Σ v⊗phi
    Vv=np.zeros((N,V),np.float32); Vv[np.arange(N), vals]=1.0
    B=(phi.T@Vv)                              # (F,V), 不加 1/N 保留幅度
    return dict(keys=keys,vals=vals,A=A,G=G,B=B,embd=embd,D=D,F=F,V=V)

def query(M, key_id, noise=0.0, rng=None):
    k=M['embd'][key_id][None,:]               # (1,D)
    if noise and rng is not None:
        k=k+rng.standard_normal(k.shape).astype(np.float32)*noise
    phi=gelu(k@M['A'])*(k@M['G'])
    return (phi@M['B'])[0]

if __name__=='__main__':
    V=2000; D=192; F=512
    for N in (1,5,20,50,100):
        M=build(N,D,F,V,seed=N)
        # 训练 key 命中
        hit=sum(int(query(M,int(k)).argmax())==int(v) for k,v in zip(M['keys'],M['vals']))
        print(f"N={N:4d}  训练key命中 {hit}/{N}", end="")
        # held-out: 实际上 key 都是随机新 token, 这里测噪声鲁棒性
        rng=np.random.default_rng(99)
        hit2=sum(int(query(M,int(k),noise=0.3,rng=rng).argmax())==int(v)
                 for k,v in zip(M['keys'],M['vals']))
        print(f"   带噪(0.3)命中 {hit2}/{N}")
