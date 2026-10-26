"""确认 ckpt 会做 arith (a+b mod 10). 格式 [S,a,S+1,b,S+2,r,S+3], S=10."""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt
S=10
for mode in ('fp32','bitnet'):
    f='ckpt_fp32.npz' if mode=='fp32' else 'ckpt_bitnet.npz'
    m,_=build_from_ckpt(dict(np.load(f)),mode=mode,strict=True)
    ok=tot=0
    for a in range(10):
        for b in range(10):
            toks=np.array([[S,a,S+1,b,S+2]],np.int64)
            o=m.forward(toks)
            # 位置4 (S+2, idx4) 的下一 token 应是 (a+b)%10
            pred=int(o[0,4].argmax()); tot+=1; ok+= (pred==(a+b)%10)
    print(f"[{mode}] arith 命中 {ok}/{tot} = {ok/tot:.2f}")
