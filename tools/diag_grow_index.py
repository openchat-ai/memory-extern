"""§10.34d 生长池子到 ~1000: 精度/覆盖率曲线随 N 的变化.

新干扰项 = 99 个已用国家的 population/president/area 模板 + 80 个新国家的原模板.
只编码(1.3 s/条), 不改旧索引.
"""
import os, sys, time, re
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OLD = os.path.join(HERE, "data", "retr_index.npz")
NEW = os.path.join(HERE, "data", "retr_index_1k.npz")
EXTRA = """Afghanistan Bahamas Barbados Belize Bermuda Bhutan2 Burkina Botswana2 CapeVerde
CentralAfrican Comoros CostaRica Cuba Cyprus Czechia DRC ElSalvador EqGuinea Fiji Greece
Grenada HongKong Iran Iraq IvoryCoast Laos Liechtenstein Macau Macedonia Mali Malta
Mauritania Mauritius Micronesia Monaco Nauru Nepal Netherlands NewZealand Nicaragua Niger
NorthKorea Norway Oman Palau Palestine PNG Peru Philippines Poland PuertoRico Qatar Rwanda
Samoa SanMarino SaudiArabia Seychelles SierraLeone Singapore Solomon SouthAfrica SouthKorea
SouthSudan SriLanka Suriname Sweden Taiwan Tajikistan TimorLeste Togo Tonga Trinidad Turkey
Turkmenistan Tuvalu UAE UK USA Uzbekistan Vanuatu Vatican Sahara""".split()
z = np.load(OLD, allow_pickle=True)
keys = [str(x) for x in z["keys"]]; values = [str(x) for x in z["values"]]
vecs = [z["vecs"][i] for i in range(len(keys))]
have = set(keys)
ent = set()
for k, v in zip(keys, values):
    if v.strip() == "(no value)":
        m = re.match(r"The (capital|currency|language) of (.+) is$", k)
        if m: ent.add(m.group(2))
new = []
for c in sorted(ent):
    for t in ("The population of %s is", "The president of %s is", "The area of %s is"):
        k = t % c
        if k not in have: new.append(k); have.add(k)
for c in EXTRA:
    for t in ("The capital of %s is", "The currency of %s is", "The language of %s is"):
        k = t % c
        if k not in have: new.append(k); have.add(k)
print(f"[plan] 旧 {len(keys)} + 新 {len(new)} = {len(keys)+len(new)} 条", flush=True)
m = RetrievalMemory()
m.keys, m.values, m.vecs = list(keys), list(values), list(vecs)
W = m.writer
t0 = time.time()
for i, k in enumerate(new):
    m.add(k, "(no value)")
    if (i + 1) % 25 == 0:
        el = time.time() - t0
        print(f"  {i+1}/{len(new)}  {el:.0f}s  {el/(i+1):.2f} s/条  "
              f"剩余 {(len(new)-i-1)*el/(i+1)/60:.1f} min", flush=True)
print(f"[enc] {len(new)} 条 {time.time()-t0:.0f}s", flush=True)
m.keys, m.values, m.vecs = list(m.keys), list(m.values), list(m.vecs)
m.save(NEW)
print(f"[save] {NEW} {os.path.getsize(NEW)/1e6:.1f} MB  N={len(m)}", flush=True)

rows = []
for ln in open(os.path.join(HERE, "data", "retr_queries_heldout.txt"), encoding="utf-8"):
    ln = ln.strip()
    if ln and not ln.startswith("#"):
        rows.append([x.strip() for x in ln.split("|")])
def norm(s): return "".join(c.lower() if c.isalnum() else " " for c in s).split()
def hit(a, b):
    x, y = norm(a), norm(b)
    return bool(y) and (" ".join(y) in " ".join(x) or (len(y[-1]) >= 4 and y[-1] in x))
def curve(mm, tag):
    res = []
    for q, want, style in rows:
        cand = [(k, v, s) for k, v, s in mm.query(q, top=40) if v.strip() != "(no value)"]
        if len(cand) < 2: continue
        res.append((cand[0][2] - cand[1][2], cand[0][0] == want))
    res.sort(reverse=True)
    n = len(res); out = []
    for cov in (0.8, 0.9, 1.0):
        k = max(1, int(round(cov * n))); c = sum(r[1] for r in res[:k])
        out.append(f"{cov*100:.0f}%@{c/k*100:.0f}%")
    print(f"[{tag}] N={len(mm)}  " + "  ".join(out) + f"  (n={n})", flush=True)
    return res
old = RetrievalMemory(OLD)
curve(old, "旧")
res5 = curve(m, "1k")
print("[1k 最不自信 5 条]", flush=True)
for mg, ok in res5[-5:]:
    print(f"  margin {mg:+.4f} {'ok' if ok else 'MISS'}", flush=True)
