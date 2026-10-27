import os, sys, time, random, json
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CK = os.path.join(HERE, "data", "curve1k.npz")

ONS, VOW, COD = "bdfgklmnprstvz", "aeiou", "nlrst"
def gen_names(n):
    out, seen = [], set()
    for a in ONS:
        for b in VOW:
            for c in COD:
                for d in VOW:
                    nm = (a + b + c + d).capitalize()
                    if nm in seen: continue
                    seen.add(nm); out.append(nm)
                    if len(out) >= n: return out
    return out
names = gen_names(870)
keys_new = [f"The capital of {x} is" for x in names]

if os.path.exists(CK):
    z = np.load(CK, allow_pickle=True)
    keys = list(z["keys"]); vecs = list(z["vecs"]); qtext = list(z["qtext"]); qvec = list(z["qvec"])
    print(f"[resume] {len(keys)} keys / {len(qtext)} queries", flush=True)
else:
    keys, vecs, qtext, qvec = [], [], [], []
have = set(keys)
m = RetrievalMemory()
t0 = time.time()
for i, k in enumerate(keys_new):
    if k in have: continue
    vecs.append(m.encode(k)); keys.append(k)
    if len(keys) % 100 == 0:
        np.savez(CK, keys=np.array(keys), vecs=np.stack(vecs),
                 qtext=np.array(qtext, dtype=object),
                 qvec=np.stack(qvec) if qvec else np.zeros((0, 2, 3072)))
        print(f"  {len(keys)}/{len(keys_new)}  {time.time()-t0:.0f}s", flush=True)
rows = [l.strip().split("|") for l in open(os.path.join(HERE, "data", "retr_facts.txt"), encoding="utf-8")
        if l.strip() and not l.startswith("#")]
for r in rows:
    if len(r) >= 3 and r[0].split()[1] == "capital":
        qtext.append(r[2]); qvec.append(m.encode(r[2]))
np.savez(CK, keys=np.array(keys), vecs=np.stack(vecs),
         qtext=np.array(qtext, dtype=object), qvec=np.stack(qvec))
print(f"done {len(keys)} keys + {len(qtext)} queries in {time.time()-t0:.0f}s", flush=True)
