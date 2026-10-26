"""用刚训出的小模型(L4 D64 F256 V2400 blk32)验证 arith 命中, 再谈定位."""
import numpy as np, sys
sys.path.insert(0,'tools')
import qxn_train as Q
from qxn_train import make_data, loss_on

# 重新训练并保留模型对象 (400步 ~1min)
m=Q.QxN(4,64,4,256,2400,32,mode='fp32',seed=0,use_gamma=False)
toks=make_data(2400,32,8,seed=1234,task='arith')
Q.train(m,toks,400,3e-3,seed=0)
print("train loss", loss_on(m.forward(toks),toks))

S=10
ok=tot=0
for a in range(10):
    for b in range(10):
        t=np.array([[S,a,S+1,b,S+2]],np.int64)
        o=m.forward(t)
        pred=int(o[0,4].argmax()); tot+=1; ok+=(pred==(a+b)%10)
print(f"arith 命中 {ok}/{tot}")
# 保存
np.savez('ckpt_arith.npz', **{k:v for k,v in m.P.items()})
print("saved ckpt_arith.npz")
