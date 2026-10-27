"""§10.34c margin 阈值: 只答高分差, 其余弃权 -> 覆盖率/准确率曲线."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
m = RetrievalMemory(os.path.join(HERE, "data", "retr_index.npz"))
rows = []
for ln in open(os.path.join(HERE, "data", "retr_queries_heldout.txt"), encoding="utf-8"):
    ln = ln.strip()
    if ln and not ln.startswith("#"):
        rows.append([x.strip() for x in ln.split("|")])
res = []
for q, want, style in rows:
    cand = [(k, v, s) for k, v, s in m.query(q, top=40) if v.strip() != "(no value)"]
    (k1, v1, s1), (k2, v2, s2) = cand[0], cand[1]
    res.append((s1 - s2, k1 == want, q, v1, s1))
res.sort(reverse=True)
n = len(res)
print(f"{'coverage':>8s} {'answer':>7s} {'correct':>8s} {'acc':>6s}")
for cov in (0.3, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0):
    k = max(1, int(round(cov * n)))
    c = sum(r[1] for r in res[:k])
    print(f"{cov*100:7.0f}% {k:7d} {c:8d} {c/k*100:5.1f}%")
print("\n按 margin 排序 (前=最自信):")
for mg, ok, q, v, s in res:
    print(f"  {mg:+.4f} {'ok ' if ok else 'MISS'} {q[:44]:44s} -> {v}")
