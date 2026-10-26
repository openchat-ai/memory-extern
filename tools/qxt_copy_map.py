"""copy 任务: X,X,X -> Y,Y,Y. 找出映射表, 这是一组真实事实."""
import numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import build_from_ckpt
m,_=build_from_ckpt(dict(np.load('ckpt_fp32.npz')),mode='fp32',strict=True)
# 对每个 token x, 输入 [x,x,x], 看第三个位置的预测
hits=[]
for x in range(0, 40):
    toks=np.array([[x,x,x]],np.int64)
    o=m.forward(toks)
    y=int(o[0,2].argmax())
    if y==x: continue
    hits.append((x,y,int(o[0,2].max()),int(np.sort(o[0,2])[-2])))
print("x -> y (pred, top1logit, top2logit):")
for x,y,l1,l2 in hits[:30]:
    print(f"  {x:3d} -> {y:6d}  gap={l1-l2:6.3f}")
print(f"共 {len(hits)} 条映射")
