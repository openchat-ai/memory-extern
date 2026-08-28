#!/usr/bin/env python3
# 替身增强实验: 全局热度(≈correction_bias代理) + 层内热度 融合
# 决定评分 = alpha*全局热度 + (1-alpha)*层内热度, 取 top16
import struct
from collections import defaultdict, Counter
L_MOE=92; TOP_K=16
d=open('/data/data/com.termux/files/home/sram/data/expert_trace.bin','rb').read()
recs=[struct.unpack('<II',d[i*8:i*8+8]) for i in range(len(d)//8)]
per_layer=defaultdict(list)
for (lay,exp) in recs: per_layer[lay].append(exp)

glob=defaultdict(int)
for (lay,exp) in recs: glob[exp]+=1

def eval_alpha(alpha):
    tot=0;hit=0
    for lay in range(1,L_MOE+1):
        seq=per_layer[lay]
        n=len(seq)
        if n<TOP_K*3: 
            continue
        lf=Counter()
        for e in seq[:TOP_K]: lf[e]+=1
        # 层内归一化分母(lf 最大值)
        for i in range(TOP_K,n):
            target=seq[i]
            # 对每个候选专家打分: 融合全局+层内
            # 高效: 只对"出现过"的专家(dict 查询)打分
            # global 部分: 固定, 层内部分: 动态
            # 候选集 = 全局top用过的 ∪ 层内用过的
            # 直接对 top-TOP_K 打分即可: 需要 max 分数筛选
            best=None
            # 简单方案: 遍历一个合并候选集
            cands=set(list(lf.keys()))
            # 只取排前面的; 用近似
            # 打分
            gm=max(glob.values()) if glob else 1
            lm=max(lf.values()) if lf else 1
            scores=[]
            for e in cands:
                sc=alpha*(glob.get(e,0)/gm) + (1-alpha)*(lf.get(e,0)/lm)
                scores.append((sc,e))
            # 不足16个候选则补全局
            if len(scores)<TOP_K:
                extra=set(sorted(glob,key=lambda e:-glob[e])[:TOP_K])
                for e in extra:
                    if e not in cands:
                        scores.append((alpha*(glob.get(e,0)/gm),e))
                        cands.add(e)
            scores.sort(key=lambda x:-x[0])
            cand=set(e for _,e in scores[:TOP_K])
            tot+=1
            if target in cand: hit+=1
            lf[target]+=1
    return hit/tot if tot else 0

for alpha in [0.0,0.25,0.5,0.75,1.0]:
    hr=eval_alpha(alpha)
    print(f"  alpha={alpha:>4}: 命中={hr*100:.1f}%")
