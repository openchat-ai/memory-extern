"""§10.34b 外部效度: 手工新问法 (与索引模板完全不同) 下的检索."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
m = RetrievalMemory(os.path.join(HERE, "data", "retr_index.npz"))
rows = []
for ln in open(os.path.join(HERE, "data", "retr_queries_heldout.txt"), encoding="utf-8"):
    ln = ln.strip()
    if ln and not ln.startswith("#"):
        rows.append([x.strip() for x in ln.split("|")])
h1 = h3 = 0
per = {}
for q, want, style in rows:
    got = m.query(q, top=3)
    ok1 = got[0][0] == want
    ok3 = any(k == want for k, _, _ in got)
    h1 += ok1; h3 += ok3
    attr = want.split()[1]; per.setdefault(attr, [0, 0]); per[attr][0] += ok1; per[attr][1] += 1
    print(f"{'ok ' if ok1 else 'MISS'} {q!r:46s} -> {got[0][1]:16s} ({got[0][2]:.3f})"
          + ("" if ok1 else f"   want {want.split()[-1]}"), flush=True)
n = len(rows)
print(f"\nheld-out top1 {h1}/{n} = {h1/n*100:.1f}% | top3 {h3}/{n} = {h3/n*100:.1f}%"
      f"  (索引内改写查询是 88.9%)")
for k, (a, b) in per.items():
    print(f"  {k:10s} {a}/{b}")
