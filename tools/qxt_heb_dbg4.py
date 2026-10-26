import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, wv, gelu
rng=np.random.default_rng(2); V,D,F,BLK=18540,192,384,64; SEG=16
model,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
W2o=model.P['l0.w2'].copy()
toks=rng.integers(0,V,size=(1,SEG),dtype=np.int64)
_,caches,_,_,_=model.forward(toks,collect=True)
hh=caches[0]['hh'][0]
pos=15
phi=gelu(hh[pos:pos+1]@model.P['l0.w1'])*(hh[pos:pos+1]@model.P['l0.w3'])  # (1,384)
tgt=11722; Wo=wv(model,'out'); v=Wo[:,tgt]
base=model.forward(toks)[0,pos]
print("base @tgt", base[tgt], "max", base.max())
# 抬升 = dff @ Wo[:,tgt], dff = phi@dW2
# 取 dW2 = c * phi^T ⊗ v^T  => dff = c*(phi@phi) * v
pp=float((phi@phi.T).ravel()[0])
# dOut[tgt] = dff@v = c*pp*(v@v)
vv=float(v@v)
print("|phi|^2",pp,"|v|^2",vv)
# 要 dOut[tgt]=Delta:  c = Delta/(pp*vv)
for Delta in (5,10,15,20):
    c=Delta/(pp*vv)
    dW2=c*np.outer(phi[0],v)
    model.P['l0.w2']=(W2o+dW2).astype(np.float32)
    o=model.forward(toks)[0,pos]
    print(f"Delta={Delta:3} |dW2|={np.linalg.norm(dW2):9.4f} @tgt={o[tgt]:9.3f} "
          f"max={o.max():8.3f} argmax={o.argmax():6d} {'HIT' if o.argmax()==tgt else ''}")
