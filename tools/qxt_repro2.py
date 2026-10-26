import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, make_data, loss_on, QxN
import numpy as np

# 训练的确切配置 (从日志: 0.68M params, 400 steps)
# 需要知道 n_layer/n_embd/n_head/n_ff. 从 ckpt 反推.
P=dict(np.load('ckpt_fp32.npz'))
D=P['l0.wq'].shape[0]; F=P['l0.w1'].shape[1]; V=P['out'].shape[1]
L=1+max(int(k.split('.')[0][1:]) for k in P if k.startswith('l') and k.split('.')[0][1:].isdigit())
blk=int(P['posembd'].shape[0])
print(f"ckpt: L={L} D={D} F={F} V={V} blk={blk}")

# 用训练的确切路径: QxN(L,D,4,F,V,32,...) + 载入
m=QxN(L,D,4,F,V,32,mode='fp32',seed=0,use_gamma=False)
print("param count", sum(v.size for v in m.P.values())/1e6, "M (日志 0.68M)")
for k,v in P.items():
    if k in m.P and m.P[k].shape==v.shape:
        m.P[k]=v.astype(np.float32)
toks=make_data(18540,32,8,seed=1234,task='arith')
o=m.forward(toks)
print("loss (block=32, seed0, nogamma) =", loss_on(o,toks))
