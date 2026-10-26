"""§10.36 运行时 query-keyed 注入: 它到底携带查询信息吗?

对照: 用"错误查询"作 key, 写同一答案 -> 若排名照样提升, 则注入与查询无关,
退化为 logit 偏置(因为 key 与读出在同一位置, 读出恒为 c·v).
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter

FACTS = [("France","Paris"),("Japan","Tokyo"),("Egypt","Cairo"),("Peru","Lima"),
         ("China","Beijing"),("Spain","Madrid"),("Italy","Rome"),("Greece","Athens"),
         ("Qatar","Doha"),("Oman","Muscat"),("Canada","Ottawa"),("Norway","Oslo")]
L, C = 18, 60.0
H = HebbWriter(); E = H.eng

facts = []
for c, a in FACTS:
    tgt = H.target_id(a)
    if len(E.encode(" " + a)) != 1:
        print(f"[skip] {a} 非单 token"); continue
    facts.append((c, a, tgt, f"What city is the capital of {c}?"))
print(f"[facts] {len(facts)} 条, L={L} c={C}", flush=True)

base = []
for c, a, tgt, q in facts:
    lo = H.forward(np.array(E.encode(q), np.int64))
    base.append(int((lo > lo[tgt]).sum()))
print(f"[baseline] 平均 rank {np.mean(base):.1f}, top1 {sum(r==0 for r in base)}/{len(facts)}", flush=True)

match, mism = [], []
for i, (c, a, tgt, q) in enumerate(facts):
    for tag, qq, out in (("matched", q, match), ("mismatch", facts[(i+1) % len(facts)][3], mism)):
        r, _ = H.write(qq, a, c=C, layers=[L])
        H.restore([L])
        out.append(r)
print(f"matched  (自己的查询作 key) : 平均 rank {np.mean(match):6.1f}  top1 {sum(r==0 for r in match)}/{len(match)}")
print(f"mismatch (别人的查询作 key) : 平均 rank {np.mean(mism):6.1f}  top1 {sum(r==0 for r in mism)}/{len(mism)}")
print(f"baseline                   : 平均 rank {np.mean(base):6.1f}  top1 {sum(r==0 for r in base)}/{len(base)}")
