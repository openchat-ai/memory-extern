"""§10.39b 给模型 3 个候选, 它会不会挑? (检索 top1 81.5% / 答案在 top3 96.3%)"""
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
m = RetrievalMemory(os.path.join(HERE, "data", "retr_index.npz"))
E = HebbWriter().eng
def norm(s): return "".join(c.lower() if c.isalnum() else " " for c in s).split()
def hit(text, value):
    t, v = norm(text), norm(value)
    if not v: return False
    if " ".join(v) in " ".join(t): return True
    return len(v[-1]) >= 4 and v[-1] in t
def gen(p, n=4):
    ids = list(E.encode(p)); lg, cache = E.forward(np.array(ids, np.int64)); out=[]
    for _ in range(n):
        t = int(np.argmax(lg)); out.append(t)
        lg, cache = E.forward(np.array([t], np.int64), cache)
    return E.decode_text(out).strip()
ok = rank1 = 0; gold_present = 0; n = 0
for q, want, style in rows:
    gold = want.split()[-1] if not want.endswith(" is") else ""
    gold = " ".join(want.split()[3:])   # "The capital of France is" -> 去掉 The/capital/of/<country>/is 不可靠
    gold = m.values[m.keys.index(want)]
    opts = []
    for k, v, s in m.query(q, top=12):
        v = v.strip()
        if v and v != "(no value)" and all(v.lower() != o.lower() for o in opts):
            opts.append(v)
        if len(opts) == 3: break
    n += 1
    gp = any(hit(gold, o) for o in opts); gold_present += gp
    top1k = m.query(q, top=1)[0][0]
    rank1 += (top1k == want)
    prompt = ("Question: " + q + "\nOptions:\n" +
              "\n".join(f"{i+1}. {o}" for i, o in enumerate(opts)) + "\nAnswer:")
    g = gen(prompt)
    good = hit(g, gold)
    ok += good
    print(f"{'ok ' if good else 'MISS'} {q[:40]:40s} gold={gold:12s} gold_in3={gp} -> {g[:28]!r}"
          f"  opts={opts}", flush=True)
print(f"\n模型选对 {ok}/{n} = {ok/n*100:.1f}% | 仅取 top1 {rank1}/{n} = {rank1/n*100:.1f}%"
      f" | 答案在 3 候选内 {gold_present}/{n} = {gold_present/n*100:.1f}%")
