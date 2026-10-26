"""定位: 8 条真实事实 (a,b)->r. 用逐张量置零, 看哪条事实崩掉.
判据: top-1 命中 (非 logit, §10.1). 对照: 置零随机张量应不崩(§11.8 区分力)."""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import QxN, wv

P=dict(np.load('ckpt_arith.npz'))
m=QxN(4,64,4,256,2400,32,mode='fp32',seed=0,use_gamma=False)
for k,v in P.items():
    if k in m.P and m.P[k].shape==v.shape: m.P[k]=v.astype(np.float32)

FACTS=[(1,2,3),(2,6,8),(5,1,6),(6,8,4),(7,3,0),(9,2,1),(9,3,2),(9,6,5)]
S=10
def hit():
    o=0
    for a,b,r in FACTS:
        t=np.array([[S,a,S+1,b,S+2]],np.int64)
        if int(m.forward(t)[0,4].argmax())==r: o+=1
    return o
print("baseline hit:", hit(), "/8")

# 逐张量置零(只对 hidden 权重, 不动 embd/norm)
keys=[k for k in m.P if any(x in k for x in ('wq','wk','wv','wo','w1','w2','w3'))]
print("测试张量数:",len(keys))
res=[]
for k in keys:
    orig=m.P[k].copy()
    m.P[k]=np.zeros_like(orig)
    res.append((hit(),k))
    m.P[k]=orig
res.sort()
print("置零后 hit (低=该张量承载事实):")
for h,k in res[:8]: print(f"  hit={h}/8  {k}")
