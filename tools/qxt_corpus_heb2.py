"""只用"一对一"的 key (单后继), 看论文外积能否命中真实语料 (§11.2 定位)."""
import json, numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import gelu
from collections import defaultdict

codes=[]
with open('magicoder_a3.jsonl') as f:
    for i,line in enumerate(f):
        if i>=5000: break
        codes.append(json.loads(line)['code'])
text='\n'.join(codes)
chars=sorted(set(text)); c2i={c:i for i,c in enumerate(chars)}; V=len(chars)

# 只保留单后继 (一对一) 的 key->val
succ=defaultdict(set)
for a,b in zip(text,text[1:]):
    succ[c2i[a]].add(c2i[b])
ones=[(k,list(v)[0]) for k,v in succ.items() if len(v)==1]
print(f"一对一事实: {len(ones)} 条 (来自 {len(succ)} 个 key)")
keys=np.array([k for k,_ in ones],np.int64)
vals=np.array([v for _,v in ones],np.int64)

def run(D,F,seed=1):
    rng=np.random.default_rng(seed)
    A=rng.standard_normal((D,F)).astype(np.float32)
    G=rng.standard_normal((D,F)).astype(np.float32)
    embd=rng.standard_normal((V,D)).astype(np.float32)*0.1
    K=embd[keys]; phi=gelu(K@A)*(K@G)
    Vv=np.zeros((len(ones),V),np.float32); Vv[np.arange(len(ones)),vals]=1.0
    B=phi.T@Vv
    # 命中
    pred=(phi@B).argmax(1)
    h=int((pred==vals).sum())
    # 随机B对照
    Br=rng.standard_normal(B.shape).astype(np.float32)
    hr=int(((phi@Br).argmax(1)==vals).sum())
    return h,hr

for D,F in ((64,256),(128,512),(192,1024),(256,2048)):
    h,hr=run(D,F)
    print(f"D={D:3d} F={F:5d}  一对一命中 {h}/{len(ones)} ({h/len(ones)*100:.1f}%)  随机B {hr}")
