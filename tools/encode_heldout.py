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
m = RetrievalMemory()
Q = np.stack([m.encode(r[0]) for r in rows])
np.savez(os.path.join(HERE, "data", "heldout_qvecs.npz"), Q=Q,
         q=np.array([r[0] for r in rows]), want=np.array([r[1] for r in rows]))
print("saved", Q.shape, flush=True)
