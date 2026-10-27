"""§10.39b(2) 打乱选项顺序, 测模型是"按内容挑"还是"按位置答 1"."""
import os, sys, re
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
rng = np.random.default_rng(7)
ok = always1 = n = 0; by_content = 0
for q, want, style in rows:
    gold = m.values[m.keys.index(want)]
    opts = []
    for k, v, s in m.query(q, top=40):
        v = v.strip()
        if v and v != "(no value)" and all(v.lower() != o.lower() for o in opts):
            opts.append(v)
        if len(opts) == 3: break
    gp = [i for i, o in enumerate(opts) if hit(o, gold)]
    rng.shuffle(opts)
    pos = [i for i, o in enumerate(opts) if hit(o, gold)]
    prompt = ("Question: " + q + "\nOptions:\n" +
              "\n".join(f"{i+1}. {o}" for i, o in enumerate(opts)) + "\nAnswer:")
    g = gen(prompt)
    chosen = None
    for i, o in enumerate(opts):
        if hit(g, o):
            chosen = i; break
    if chosen is None:
        d = re.search(r"[1-9]", g)
        chosen = int(d.group()) - 1 if d and int(d.group()) <= len(opts) else None
    good = chosen is not None and hit(opts[chosen], gold)
    n += 1; ok += good
    always1 += bool(pos) and pos[0] == 0
    if good and chosen != 0: by_content += 1
    print(f"{'ok ' if good else 'MISS'} {q[:38]:38s} gold_pos={pos[0]+1 if pos else 0} "
          f"chose={chosen+1 if chosen is not None else '-'} {g[:22]!r} {opts}", flush=True)
print(f"\n模型选对 {ok}/{n} = {ok/n*100:.1f}% | 总选第1项 {sum(1 for _ in [])}"
      f" | 正确项在第1位的比例 {always1}/{n} = {always1/n*100:.1f}%")
