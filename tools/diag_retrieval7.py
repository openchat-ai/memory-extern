"""§10.34 语言属性: 有/无共同内容词时的召回差异."""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter
z = np.load("/data/data/com.termux/files/home/sram/data/retr_real.npz")
V = z["v"]
POOL = ("France Japan Egypt Peru Brazil Chile China Spain Italy Greece Kenya Nepal "
        "Qatar Oman India Canada Mexico Norway Sweden Poland Turkey Iran Iraq Cuba "
        "Ghana Mali Laos Fiji Tonga Malta").split()
NPOOL = len(POOL) * 3
VARS = {"tongue(无共同词)": "What tongue do people speak in {}?",
        "language(有共同词)": "What language do they speak in {}?",
        "official(有共同词)": "What is the official language of {}?"}
H = HebbWriter(); E = H.eng
def lean(t):
    _, p = H.capture_vecs(np.array(list(E.encode(t)), np.int64))
    return np.stack([p[4].mean(0), p[6].mean(0)]).astype(np.float32)
def cos(A, q): return A @ q / (np.linalg.norm(A, axis=1)*np.linalg.norm(q)+1e-9)
A4 = V[:,0,:]/ (np.linalg.norm(V[:,0,:],axis=1,keepdims=True)+1e-9)
A6 = V[:,1,:]/ (np.linalg.norm(V[:,1,:],axis=1,keepdims=True)+1e-9)
print("变体                     language 命中 (N=490, 30 条查询)")
for name, tmpl in VARS.items():
    qs = [lean(tmpl.format(c)) for c in POOL]
    hits = 0
    for gi, c in enumerate(POOL):
        q = qs[gi]; g = 3*gi + 2   # language key 的全局下标
        q4 = q[0]/ (np.linalg.norm(q[0])+1e-9); q6 = q[1]/(np.linalg.norm(q[1])+1e-9)
        s = cos(A4,q4) + cos(A6,q6)
        hits += (int((s > s[g]).sum()) == 0)
    print(f"{name:24s} {hits}/30", flush=True)
