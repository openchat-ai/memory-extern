import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, wv, gelu
rng=np.random.default_rng(0); V,D,F,BLK=18540,192,384,64; SEG=16
model,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
W2o=model.P['l0.w2'].copy()
# N=1: 单个 key 段
N=1
toks=rng.integers(0,V,size=(1,N*SEG),dtype=np.int64)
_,caches,_,_,_=model.forward(toks,collect=True)
hh=caches[0]['hh'][0]
key_hh=hh[np.arange(1,N+1)*SEG-1]        # (1,192)
phi=gelu(key_hh@model.P['l0.w1'])*(key_hh@model.P['l0.w3'])
tgt=int(rng.integers(0,V))
Wo=wv(model,'out')                        # (192,18540)
v=Wo[:,tgt]; v=v/np.linalg.norm(v)
raw=phi.T@v[None,:]                        # (384,192)
frac=0.10; scale=frac*np.linalg.norm(W2o)/(np.linalg.norm(raw)+1e-12)
dW2=scale*raw
pos=N*SEG-1
print("tgt",tgt,"pos",pos)
print("base logit@tgt:", model.forward(toks)[0,pos,tgt])
model.P['l0.w2']=(W2o+dW2).astype(np.float32)
o=model.forward(toks)
print("after logit@tgt:", o[0,pos,tgt], "argmax", o[0,pos].argmax())
print("|dW2|",np.linalg.norm(dW2), "|W2|",np.linalg.norm(W2o))
print("dW2/phi@W2 check: dff = phi@dW2, norm", np.linalg.norm(phi@dW2))
