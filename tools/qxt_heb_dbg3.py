import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, wv, gelu
rng=np.random.default_rng(2); V,D,F,BLK=18540,192,384,64; SEG=16
model,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
W2o=model.P['l0.w2'].copy()
# 关键改动: 用 key 的"中间位置"(不是末位). 中间位置的自然预测通常平坦
N=1
toks=rng.integers(0,V,size=(1,N*SEG),dtype=np.int64)
_,caches,_,_,_=model.forward(toks,collect=True)
hh=caches[0]['hh'][0]
for pos in (0,1,5,8,15):
    base=model.forward(toks)[0,pos]
    # 该位置的 logits 分布有多平坦? top1 与 2nd 的差
    s=np.sort(base)[::-1]
    print(f"pos={pos:2d} argmax={base.argmax():6d} max={s[0]:7.3f} "
          f"2nd={s[1]:7.3f} gap={s[0]-s[1]:6.3f} entropy="
          f"{-(np.exp(base-base.max())/np.exp(base-base.max()).sum()*np.log(np.exp(base-base.max())/np.exp(base-base.max()).sum()+1e-12)).sum():.2f}")
