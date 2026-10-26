"""对照: 按论文原设定, A/G 随机, 验证 rank-1 注入能否命中.
同时用同一测试看 QxT 训好的 A/G -> 命中失败. 这是口径对照(§11.3)."""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, wv, gelu
rng=np.random.default_rng(3); V,D,F,BLK=18540,192,384,64; SEG=32
model,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
W2o=model.P['l0.w2'].copy()
Nh=384  # 用 F 做维度, 旁路整个网络, 纯赫布记忆测试

def hebb_test(A,G,B_scale,label):
    # 纯 φ(x)=g(Ax)⊙(Gx) 的记忆, 输入 x=随机key(D), 目标 v=随机(D)
    N=20
    X=rng.standard_normal((N,D)).astype(np.float32)
    Y=rng.standard_normal((N,D)).astype(np.float32)
    phi=gelu(X@A)*(X@G)                     # (N,F)
    # B = (1/N) Σ Y_i ⊗ phi_i  =>  phi@B = Y
    B=(1.0/N)*(phi.T@Y)                     # (F,D)
    # 测试: 用带噪 key 检索
    Xq=X+rng.standard_normal((N,D)).astype(np.float32)*0.1
    phiq=gelu(Xq@A)*(Xq@G)
    Yhat=phiq@B
    # 命中: 每个 query 恢复的 Y 是否最接近对应 Y_i (余弦)
    Yn=Y/np.linalg.norm(Y,axis=1,keepdims=True)
    Yhn=Yhat/np.linalg.norm(Yhat,axis=1,keepdims=True)
    sim=Yhn@Yn.T
    pred=sim.argmax(1); hit=(pred==np.arange(N)).sum()
    print(f"  {label}: hit={hit}/{N}  cos(diag)={np.mean(np.diag(sim)):.3f} "
          f"cos(off)={np.mean(sim[~np.eye(N,dtype=bool)]):.3f}")

print("随机 A/G (论文设定):")
A=rng.standard_normal((D,F)).astype(np.float32)
G=rng.standard_normal((D,F)).astype(np.float32)
hebb_test(A,G,1,"random A/G")
print("QxT 训好的 A=W1, G=W3:")
hebb_test(model.P['l0.w1'],model.P['l0.w3'],1,"trained W1/W3")
