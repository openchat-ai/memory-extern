"""复现训练时 loss. 若不是 1.05 -> 我的前向/数据理解和训练不一致(§11.1)."""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt, make_data, loss_on
m,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
toks=make_data(18540,32,8,seed=1234,task='arith')
print("前 3 条数据:")
for r in toks[:3]: print("  ",r.tolist())
o=m.forward(toks)
print("loss_on =", loss_on(o,toks), " (训练日志终值 0.0470)")
