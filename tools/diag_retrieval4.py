"""§10.34 决定性测试: 真实国名事实池, 换词改写, N=520.
90 查询 = 30 国 x 3 属性; 池 90 keys + 430 同类真实干扰."""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter

LS = (4, 6, 8)
CACHE = "/data/data/com.termux/files/home/sram/data/retr_real.npz"
POOL = ("France Japan Egypt Peru Brazil Chile China Spain Italy Greece Kenya Nepal "
        "Qatar Oman India Canada Mexico Norway Sweden Poland Turkey Iran Iraq Cuba "
        "Ghana Mali Laos Fiji Tonga Malta").split()
DEC = ("Argentina Australia Austria Belgium Bolivia Bulgaria Cambodia Cameroon Chad Colombia "
       "Croatia Denmark Ecuador Estonia Ethiopia Finland Germany Hungary Iceland Indonesia "
       "Ireland Israel Jamaica Jordan Kazakhstan Kuwait Latvia Lebanon Libya Lithuania "
       "Madagascar Malaysia Mongolia Morocco Mozambique Myanmar Namibia Nigeria Pakistan "
       "Panama Paraguay Portugal Romania Senegal Serbia Slovakia Slovenia Somalia Sudan "
       "Switzerland Syria Tanzania Thailand Tunisia Uganda Ukraine Uruguay Venezuela Vietnam "
       "Yemen Zambia Zimbabwe Albania Algeria Angola Armenia Azerbaijan Bahrain Bangladesh "
       "Belarus Benin Bhutan Bosnia Botswana Brunei Burundi Congo Djibouti Dominica Eritrea "
       "Eswatini Gabon Gambia Georgia Guatemala Guinea Guyana Haiti Honduras Jamaica Kiribati "
       "Kosovo Kyrgyzstan Lesotho Liberia Luxembourg Malawi Maldives Moldova Montenegro").split()
ATTR = {"capital": ("The capital of {} is", "What city is the capital of {}?"),
        "currency": ("The currency of {} is", "What money is used in {}?"),
        "language": ("The language of {} is", "What tongue do people speak in {}?")}

def cos_mat(A, q):
    return A @ q / (np.linalg.norm(A, axis=1) * np.linalg.norm(q) + 1e-12)

H = HebbWriter(); E = H.eng
def lean(text):
    _, p = H.capture_vecs(np.array(list(E.encode(text)), np.int64))
    return np.stack([p[L].mean(0) for L in LS]).astype(np.float32)

keys = [ATTR[a][0].format(c) for c in POOL for a in ATTR]
queries = [(i, ATTR[a][1].format(c)) for i, (c, a) in
           enumerate((c, a) for c in POOL for a in ATTR)]

allk = list(keys) + [ATTR[a][0].format(c) for c in DEC for a in ATTR]
allk += [f"The winner of the {y} FIFA World Cup is" for y in range(1930, 2030)]
print(f"[plan] keys {len(keys)}  queries {len(queries)}  decoys {len(allk)-len(keys)}", flush=True)

have = 0; vecs = []
if os.path.exists(CACHE):
    z = np.load(CACHE); old = [str(x) for x in z["keys"]]
    if old[:min(len(old), len(allk))] == allk[:min(len(old), len(allk))]:
        vecs = [z["v"][i] for i in range(len(old))]; have = len(old)
print(f"[cache] 已有 {have}", flush=True)
t0 = time.time()
for i in range(have, len(allk)):
    vecs.append(lean(allk[i]))
    if (i + 1) % 50 == 0:
        el = time.time() - t0; n = i + 1 - have
        print(f"  {i+1}/{len(allk)}  {el:.0f}s  剩余约 {el/max(n,1)*(len(allk)-i-1):.0f}s", flush=True)
    if (i + 1) % 100 == 0:
        np.savez(CACHE, keys=np.array(allk[:i+1]), v=np.stack(vecs))
qv = [lean(t) for _, t in queries]
np.savez(CACHE, keys=np.array(allk), v=np.stack(vecs), qkeys=np.array([t for _, t in queries]),
         qv=np.stack(qv))
print(f"[done] 键 {len(allk)} 查询 {len(qv)}  用时 {time.time()-t0:.0f}s", flush=True)

allv = np.stack(vecs).astype(np.float32); qall = np.stack(qv)
for li, L in enumerate(LS):
    dv = allv[:, li, :]
    hits = 0; ranks = []
    for (gi, _), q in zip(queries, qall[:, li, :]):
        s = cos_mat(dv, q)
        rank = int((s > s[gi]).sum())
        ranks.append(rank); hits += (rank == 0)
    print(f"L={L} phi/mean  N={len(allk)}: top1 {hits}/{len(queries)} = {hits/len(queries)*100:.1f}%"
          f"  中位rank {int(np.median(ranks))}  p90 {int(np.percentile(ranks,90))} 最差 {max(ranks)}",
          flush=True)
