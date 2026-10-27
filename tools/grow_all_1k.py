import os, sys, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CK = os.path.join(HERE, "data", "curve1k_all.npz")
ONS, VOW, COD = "bdfgklmnprstvz", "aeiou", "nlrst"
names, seen = [], set()
for a in ONS:
    for b in VOW:
        for c in COD:
            for d in VOW:
                nm = (a+b+c+d).capitalize()
                if nm not in seen:
                    seen.add(nm); names.append(nm)
names = names[:870]
keys_new = [f"The {at} of {x} is" for at in ("capital","currency","language") for x in names]
if os.path.exists(CK):
    z = np.load(CK, allow_pickle=True)
    keys=list(z["keys"]); vecs=list(z["vecs"]); qk=list(z["qk"]); qv=list(z["qv"])
    print(f"[resume] {len(keys)} keys", flush=True)
else:
    keys, vecs, qk, qv = [], [], [], []
have=set(keys); m=RetrievalMemory(); t0=time.time()
for k in keys_new:
    if k in have: continue
    vecs.append(m.encode(k)); keys.append(k)
    if len(keys) % 200 == 0:
        np.savez(CK, keys=np.array(keys), vecs=np.stack(vecs),
                 qk=np.array(qk,dtype=object), qv=np.stack(qv) if qv else np.zeros((0,2,3072)))
        print(f"  {len(keys)}/{len(keys_new)} {time.time()-t0:.0f}s", flush=True)
rows=[[x.strip() for x in l.strip().split("|")] for l in open(os.path.join(HERE,"data","retr_facts.txt"),encoding="utf-8")
      if l.strip() and not l.startswith("#")]
for r in rows:
    qk.append(r[0]); qv.append(m.encode(r[2]))
np.savez(CK, keys=np.array(keys), vecs=np.stack(vecs), qk=np.array(qk,dtype=object), qv=np.stack(qv))
print(f"done {len(keys)} keys + {len(qk)} queries in {time.time()-t0:.0f}s", flush=True)
