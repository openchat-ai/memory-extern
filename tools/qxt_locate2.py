"""§11.8 区分力对照: 置零应能区分. 若置零 attention 与置零随机张量效果相同, 则测量无效."""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import QxN
P=dict(np.load('ckpt_arith.npz'))
m=QxN(4,64,4,256,2400,32,mode='fp32',seed=0,use_gamma=False)
for k,v in P.items():
    if k in m.P and m.P[k].shape==v.shape: m.P[k]=v.astype(np.float32)
FACTS=[(1,2,3),(2,6,8),(5,1,6),(6,8,4),(7,3,0),(9,2,1),(9,3,2),(9,6,5)]
S=10
def hit():
    o=0
    for a,b,r in FACTS:
        if int(m.forward(np.array([[S,a,S+1,b,S+2]],np.int64))[0,4].argmax())==r: o+=1
    return o
runtime=['l0.wq','l0.wk','l0.wv','l0.wo','l0.w1','l0.w2','l0.w3']
print("对照组 A: 整体权重乘 0.5 (应轻微影响)")
for k in runtime:
    orig=m.P[k].copy(); m.P[k]=(orig*0.5).astype(np.float32)
    print(f"  {k} *0.5 -> hit={hit()}/8"); m.P[k]=orig
print("对照组 B: 随机置换张量元素 (破坏结构但保幅度)")
rng=np.random.default_rng(0)
for k in runtime:
    orig=m.P[k].copy(); flat=orig.ravel().copy(); rng.shuffle(flat)
    m.P[k]=flat.reshape(orig.shape); print(f"  {k} shuffle -> hit={hit()}/8"); m.P[k]=orig
