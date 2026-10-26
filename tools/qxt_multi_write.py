"""多条事实正交写入: 解决 #16 的"污染"问题.

方法对比:
  A. 直接累加 (naive): B = Σ v_i ⊗ φ_i     ← 会串扰
  B. 正交化 (论文精神): 先对 φ 做 Gram-Schmidt, 再写入   ← 减少串扰
  C. 尺度平衡: B = (1/N)Σ...               ← 论文原式

在合成模型 (D=192 F=1024) 上测三种方法的 held-out 命中率.
"""
import numpy as np, sys, math
sys.path.insert(0,'tools')
from qxn_train import gelu

def build(D,F,V,N,seed=0, method='naive'):
    rng=np.random.default_rng(seed)
    keys=rng.integers(0,V,N); vals=rng.integers(0,V,N)
    A=rng.standard_normal((D,F)).astype(np.float32)
    G=rng.standard_normal((D,F)).astype(np.float32)
    embd=rng.standard_normal((V,D)).astype(np.float32)*0.1
    K=embd[keys]
    phi=gelu(K@A)*(K@G)                       # (N,F)
    Vv=np.zeros((N,V),np.float32); Vv[np.arange(N),vals]=1.0
    if method=='naive':
        B=phi.T@Vv
    elif method=='avg':
        B=(phi.T@Vv)/N
    elif method=='ortho':
        # 对 phi 行做 QR: phi = Q R, 用 Q 做写入基 (行正交)
        Q,_=np.linalg.qr(phi.T)               # phi.T (F,N) -> Q (F,N)
        B=Q@Vv                                 # 用正交基写入
    return dict(A=A,G=G,B=B,embd=embd,keys=keys,vals=vals,D=D,F=F,V=V)

def hit(M, noise=0.0, seed=0):
    rng=np.random.default_rng(seed)
    k=M['embd'][M['keys']]
    if noise: k=k+rng.standard_normal(k.shape).astype(np.float32)*noise
    phi=gelu(k@M['A'])*(k@M['G'])
    pred=(phi@M['B']).argmax(1)
    return int((pred==M['vals']).sum())

D,F,V=192,1024,4000
print(f"D={D} F={F} V={V}")
for meth in ('naive','avg','ortho'):
    print(f"--- {meth} ---")
    for N in (20,50,100,200,400):
        M=build(D,F,V,N,seed=N,method=meth)
        h0=hit(M); h3=hit(M,noise=0.3)
        print(f"  N={N:4d}  无噪 {h0:4d}/{N:<4d}  带噪0.3 {h3:4d}/{N:<4d}")
