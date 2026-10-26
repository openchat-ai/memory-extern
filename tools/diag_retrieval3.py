"""§10.34 规模化: phi/mean 在 N 条干扰下的 top-1.
只在采集时保留 L=4/6/8 的均值池化向量 (float32), 每条 37KB, 避免 OOM."""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter
from retr_pairs import PAIRS

N = int(sys.argv[1]) if len(sys.argv) > 1 else 200
LS = (4, 6, 8)
CACHE = "/data/data/com.termux/files/home/sram/data/retr_vecs.npz"

def cos_mat(A, q):
    return A @ q / (np.linalg.norm(A, axis=1) * np.linalg.norm(q) + 1e-12)

def lean(H, E, text):
    _, p = H.capture_vecs(np.array(list(E.encode(text)), np.int64))
    return np.stack([p[L].mean(0) for L in LS]).astype(np.float32)   # (3, F)

H = HebbWriter(); E = H.eng
real = [(lean(H, E, kp), lean(H, E, qp)) for kp, qp, _ in PAIRS]
print(f"[real] {len(real)} 条完成", flush=True)

syl = ["Zor","kav","mel","tris","vun","dral","osk","nim","bex","quel","farn","hul"]
def name(i):
    return "".join(syl[(i*7+j*3) % 12] for j in range(3)) + str(i)
keys = [f"The winner of the {y} FIFA World Cup is" for y in range(1800, 2100)]
for i in range(1000):
    c = name(i)
    keys += [f"The capital of {c} is", f"The currency of {c} is", f"The language of {c} is"]
keys = keys[:N]

have = 0
vecs = []
if os.path.exists(CACHE):
    z = np.load(CACHE)
    old = [str(x) for x in z["keys"]]
    if old[:min(len(old), len(keys))] == keys[:min(len(old), len(keys))]:
        vecs = [z["v"][i] for i in range(len(old))]
        have = len(old)
print(f"[cache] 已有 {have} 条", flush=True)
t0 = time.time()
for i in range(have, len(keys)):
    vecs.append(lean(H, E, keys[i]))
    if (i + 1) % 50 == 0 or i + 1 == len(keys):
        el = time.time() - t0; n = i + 1 - have
        print(f"  {i+1}/{len(keys)}  {el:.0f}s  剩余约 {el/max(n,1)*(len(keys)-i-1):.0f}s", flush=True)
        np.savez(CACHE, keys=np.array(keys[:i+1]), v=np.stack(vecs))
allv = np.stack(vecs).astype(np.float32)
np.savez(CACHE, keys=np.array(keys), v=allv)
print(f"[decoy] {len(keys)} 条就绪", flush=True)

for li, L in enumerate(LS):
    dv = allv[:, li, :]; rv = np.stack([p[li] for p, _ in real])
    hits = 0; ranks = []
    for i, (_, qvr) in enumerate(real):
        qv = qvr[li]
        s = np.concatenate([cos_mat(dv, qv), cos_mat(rv, qv)])
        rank = int((s > s[len(keys) + i]).sum())
        ranks.append(rank); hits += (rank == 0)
    print(f"L={L} phi/mean  N={len(keys)}: top1 {hits}/{len(real)} = {hits/len(real)*100:.0f}%"
          f"  中位rank {int(np.median(ranks))} 最差rank {max(ranks)}", flush=True)
