"""§10.39c 不用生成, 用似然给 3 个候选打分 (base 模型做多选题的正确方式)."""
import os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
from hebb_write import HebbWriter
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
rows = []
for ln in open(os.path.join(HERE, "data", "retr_queries_heldout.txt"), encoding="utf-8"):
    ln = ln.strip()
    if ln and not ln.startswith("#"):
        rows.append([x.strip() for x in ln.split("|")])
rows = rows[0::2]                       # 12 条, 风格交错
m = RetrievalMemory(os.path.join(HERE, "data", "retr_index.npz"))
E = HebbWriter().eng
def norm(s): return "".join(c.lower() if c.isalnum() else " " for c in s).split()
def hit(a, b):
    x, y = norm(a), norm(b)
    return bool(y) and (" ".join(y) in " ".join(x) or (len(y[-1]) >= 4 and y[-1] in x))
def lpscore(q, opt):
    pre = f"Question: {q}\nAnswer:"
    a = E.encode(pre)
    b = E.encode(pre + " " + opt)
    n = len(b) - len(a)
    if n <= 0: return -99.0
    lg, _ = E.forward(np.array(b, np.int64), full_logits=True)
    s = 0.0
    for j in range(n):
        z = lg[len(a) + j].astype(np.float64)
        z -= z.max(); lse = np.log(np.exp(z).sum())
        s += float(z[b[len(a) + j]] - lse)
    return s / n
ok = 0; n = 0
for q, want, style in rows:
    gold = m.values[m.keys.index(want)]
    opts = []
    for k, v, s in m.query(q, top=40):
        v = v.strip()
        if v and v != "(no value)" and not any(hit(o, v) and hit(v, o) for o in opts):
            opts.append(v)
        if len(opts) == 3: break
    sc = [lpscore(q, o) for o in opts]
    pick = int(np.argmax(sc))
    good = hit(opts[pick], gold); ok += good; n += 1
    print(f"{'ok ' if good else 'MISS'} {q[:38]:38s} gold={gold:13s} pick={opts[pick]:13s}"
          f" scores={[round(x,2) for x in sc]}", flush=True)
print(f"\n似然重排选对 {ok}/{n} = {ok/n*100:.1f}%  (top1 基线 81.5%, 3 候选内 96.3%)")
