"""从 A3 语料抽真实事实对, 测论文外积能否在真实代码分布上命中.

事实对设计: 从代码里抽 (def 名 -> 该函数第一行体) 之类的高层模式太散.
改用 token 级: 从语料取真实 token, 事实 = (前一个 token -> 后一个 token),
  但这是 bigram, 没有记忆价值.
更有价值: 函数名 -> 参数列表;  常量名 -> 值.

先做最标准的: 语料里出现的 (short prefix hash -> next token), 
  用 "key = 上下文token的隐状态" 需要随机A/G映射. 
这里先纯测容量+命中, 用合成 key (rng token) 但 val 取自语料真实 token 分布.
"""
import json, numpy as np, sys
sys.path.insert(0,'tools')
from qxn_train import gelu

# 抽真实 token: 用 A3 代码里的字符 bigram 当"事实" (真实分布)
codes=[]
with open('magicoder_a3.jsonl') as f:
    for i,line in enumerate(f):
        if i>=3000: break
        codes.append(json.loads(line)['code'])
text='\n'.join(codes)
chars=sorted(set(text))
print(f"语料: {len(codes)} 条, {len(text):,} 字符, {len(chars)} 种字符")
c2i={c:i for i,c in enumerate(chars)}
V=len(chars)

# 事实对: 语料里真实的 (char i -> char i+1) 转移, 去重
pairs=set()
for c1,c2 in zip(text,text[1:]):
    pairs.add((c2i[c1],c2i[c2]))
pairs=sorted(pairs)
print(f"真实字符转移对(去重): {len(pairs):,}")

def build(N,D,F,seed=0):
    rng=np.random.default_rng(seed)
    idx=np.arange(len(pairs)); rng.shuffle(idx)
    sub=[pairs[i] for i in idx[:N]]
    keys=np.array([p[0] for p in sub],np.int64)
    vals=np.array([p[1] for p in sub],np.int64)
    A=rng.standard_normal((D,F)).astype(np.float32)
    G=rng.standard_normal((D,F)).astype(np.float32)
    embd=rng.standard_normal((V,D)).astype(np.float32)*0.1
    K=embd[keys]; phi=gelu(K@A)*(K@G)
    Vv=np.zeros((N,V),np.float32); Vv[np.arange(N),vals]=1.0
    B=phi.T@Vv
    return dict(A=A,G=G,B=B,embd=embd,keys=keys,vals=vals,D=D,F=F,V=V)

def hit(M,keys,vals):
    k=M['embd'][keys]; phi=gelu(k@M['A'])*(k@M['G'])
    pred=(phi@M['B']).argmax(1)
    return int((pred==vals).sum())

# 用全部真实对, held-out 8:2
allkeys=np.array([p[0] for p in pairs],np.int64)
allvals=np.array([p[1] for p in pairs],np.int64)
rng=np.random.default_rng(7); perm=rng.permutation(len(pairs))
ntr=int(len(pairs)*0.8)
tr,te=perm[:ntr],perm[ntr:]
print(f"训练对 {ntr:,}  held-out {len(te):,}")

for D,F in ((64,256),(128,512),(192,1024)):
    # 只在训练对上构造 B
    A=rng.standard_normal((D,F)).astype(np.float32)
    G=rng.standard_normal((D,F)).astype(np.float32)
    embd=rng.standard_normal((V,D)).astype(np.float32)*0.1
    K=embd[allkeys[tr]]; phi=gelu(K@A)*(K@G)
    Vv=np.zeros((ntr,V),np.float32); Vv[np.arange(ntr),allvals[tr]]=1.0
    B=phi.T@Vv
    M=dict(A=A,G=G,B=B,embd=embd)
    htr=hit(M,allkeys[tr],allvals[tr])
    hte=hit(M,allkeys[te],allvals[te])
    print(f"  D={D:3d} F={F:5d}  训练命中 {htr:5d}/{ntr:,} ({htr/ntr*100:.1f}%)  "
          f"held-out {hte:4d}/{len(te):,} ({hte/len(te)*100:.1f}%)")
