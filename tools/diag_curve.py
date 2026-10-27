"""§10.34d 池子生长后的 精度-覆盖率曲线 (N=490 vs 982)."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rows = []
for ln in open(os.path.join(HERE, "data", "retr_queries_heldout.txt"), encoding="utf-8"):
    ln = ln.strip()
    if ln and not ln.startswith("#"):
        rows.append([x.strip() for x in ln.split("|")])
def curve(mm, tag):
    res = []
    for q, want, style in rows:
        cand = [(k, v, s) for k, v, s in mm.query(q, top=40) if v.strip() != "(no value)"]
        res.append((cand[0][2] - cand[1][2], cand[0][0] == want, q, cand[0][1]))
    res.sort(reverse=True)
    n = len(res); out = []
    for cov in (0.7, 0.8, 0.9, 1.0):
        k = max(1, int(round(cov * n))); c = sum(r[1] for r in res[:k])
        out.append(f"{cov*100:.0f}%->{c/k*100:.0f}%")
    print(f"[{tag}] N={len(mm):4d}  " + "  ".join(out) + f"   (n={n})", flush=True)
    return res
for path, tag in (("data/retr_index.npz", "490"), ("data/retr_index_1k.npz", "982")):
    r = curve(RetrievalMemory(os.path.join(HERE, path)), tag)
    print("   最不自信 5 条:", " ".join(f"{'-' if ok else 'X'}{mg:.4f}" for mg, ok, _, _ in r[-5:]), flush=True)
