import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt
S=10
m,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
toks=np.array([[S,3,S+1,4,S+2]],np.int64)
o=m.forward(toks)
for p in range(5):
    print(f"pos{p}={toks[0,p]:3d} -> next top5 {o[0,p].argsort()[-5:][::-1].tolist()} "
          f"argmax={int(o[0,p].argmax())}")
# 试试各种任务格式
for name,seq in [("copy",[1,1,1,2,2,2]),("arith-noS",[3,4]),("plain",[0,1,2,3])]:
    toks=np.array([seq],np.int64)
    try:
        o=m.forward(toks)
        print(name, seq, "->", [int(o[0,p].argmax()) for p in range(len(seq))])
    except Exception as e: print(name,"ERR",e)
