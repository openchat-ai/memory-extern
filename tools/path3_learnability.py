#!/usr/bin/env python3
"""路径3可学性探针(纯Python): 低秩router逼近真gate top16的可学性。
对照 exp1 输出: structured(可学) vs random(不可学,§7实测更像后者)。"""
import math, random
from collections import Counter

def dot(a,b): return sum(x*y for x,y in zip(a,b))

def build(mode, n_act, n_exp, topk, samples, rank, seed):
    rng = random.Random(seed)
    def gauss(): return rng.gauss(0,1)
    # 低秩真gate打分系数: V[exp,rank]
    U = [[gauss() for _ in range(rank)] for _ in range(n_act)]
    V = [[gauss() for _ in range(rank)] for _ in range(n_exp)]
    fixed_top_hit = 0; tot = 0
    cnt = Counter()
    data = []
    for _ in range(samples):
        h = [gauss() for _ in range(n_act)]
        if mode == 'structured':
            # score[e] = sum_r <h,U[:,r]> V[e,r]
            ur = [[sum(h[i]*U[i][r] for i in range(n_act)) for r in range(rank)]]
            sc = [sum(ur[0][r]*V[e][r] for r in range(rank)) for e in range(n_exp)]
        else:
            sc = [gauss() for _ in range(n_exp)]
        top = sorted(range(n_exp), key=lambda e: -sc[e])[:topk]
        tot += topk
        for e in top: cnt[e] += 1
        data.append(set(top))
    hot16 = set(e for e,_ in cnt.most_common(topk))
    for s in data:
        fixed_top_hit += len(s & hot16)
    return fixed_top_hit/tot*100, cnt.most_common(1)[0][1]/len(data)*100

for mode in ['structured','random']:
    hit, hotrep = build(mode, 64, 896, 16, 1500, 4, 0)
    print(f"[{mode:11}] 固定top16集命中 = {hit:.1f}%   最热专家重复度 = {hotrep:.0f}%")

print("""
读法(对照你的 exp1):
- structured(低秩可学): 固定top16命中高(>60%), 专家高度重复
- random(不可学): 固定top16命中≈topk/n_exp≈1.8%, 几乎不重复
- §7实测每层108.8唯一专家 → 更像random/弱可学 => 低秩router学不动
你的 exp1: 看低秩router在未见激活上的top16命中, 对照上面两档判断K3属哪类""")
