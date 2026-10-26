import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, wv, gelu
rng=np.random.default_rng(1); V,D,F,BLK=18540,192,384,64; SEG=16
model,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
W2o=model.P['l0.w2'].copy()
N=1
toks=rng.integers(0,V,size=(1,N*SEG),dtype=np.int64)
_,caches,_,_,_=model.forward(toks,collect=True)
hh=caches[0]['hh'][0]; key_hh=hh[np.arange(1,N+1)*SEG-1]
phi=gelu(key_hh@model.P['l0.w1'])*(key_hh@model.P['l0.w3'])
tgt=11722; pos=N*SEG-1
Wo=wv(model,'out')
base=model.forward(toks)[0,pos]
print("base argmax",base.argmax(),"max",base.max(),"@tgt",base[tgt])
# 直接精确构造: 想要 dff 使 out[:,tgt] 抬 Dtarget
# out=ff@Wo, dOut[tgt]=dff@Wo[:,tgt]. 取 dff = beta*Wo[:,tgt]/|Wo[:,tgt]|^2 => dOut[tgt]=beta
v=Wo[:,tgt]
for frac in (0.1,0.5,1.0,2.0,5.0):
    # dW2 使 phi@dW2 = (frac*|W2|)*Wo[:,tgt]/|Wo|  (挑一个能翻盘的幅度)
    dff = frac*np.linalg.norm(W2o) * v/ (np.linalg.norm(v)+1e-9)   # (192,)
    # phi(1,384) @ dW2(384,192) = dff(192) => dW2 = phi^T dff / (phi@phi)
    dW2=np.outer(phi[0],dff)/(phi[0]@phi[0])
    model.P['l0.w2']=(W2o+dW2).astype(np.float32)
    o=model.forward(toks)[0,pos]
    print(f"frac={frac:4} |dW2|={np.linalg.norm(dW2):8.2f} argmax={o.argmax():6d} "
          f"@tgt={o[tgt]:9.3f} max={o.max():9.3f} {'HIT' if o.argmax()==tgt else ''}")
