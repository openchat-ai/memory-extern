"""§10.35 注入仿真: 多条改写 key 能否泛化到"没写过的改写"?
纯数学, 不写权重. 读出 s_j = (phi_q . phi_j)/|phi_j|^2  (真实注入的读数形式).

条件:  write={key} 或 {key,A} 或 {A};  probe={A,B}; 90 路 top-1.
"""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter

POOL = ("France Japan Egypt Peru Brazil Chile China Spain Italy Greece Kenya Nepal "
        "Qatar Oman India Canada Mexico Norway Sweden Poland Turkey Iran Iraq Cuba "
        "Ghana Mali Laos Fiji Tonga Malta").split()
KEYS = [f"The {a} of {c} is" for c in POOL for a in ("capital", "currency", "language")]
A = [q for c in POOL for q in (f"What city is the capital of {c}?",
                               f"What money is used in {c}?",
                               f"What tongue do people speak in {c}?")]
B = [q for c in POOL for q in (f"Where does {c}'s government sit?",
                               f"How does {c} pay for things?",
                               f"What do people in {c} speak?")]
LAYERS = (14, 18, 22, 26)
CACHE = "data/inj_sim.npz"

H = HebbWriter(); E = H.eng
def lastphi(text):
    _, p = H.capture_vecs(np.array(list(E.encode(text)), np.int64))
    return np.stack([p[L][-1] for L in LAYERS]).astype(np.float32)   # (4, F)

sets = {"key": KEYS, "A": A, "B": B}
allk = KEYS + A + B
have = 0; vecs = []
if os.path.exists(CACHE):
    z = np.load(CACHE); old = [str(x) for x in z["texts"]]
    if old == allk:
        have = len(old); vecs = [z["v"][i] for i in range(have)]
    else:
        print("[cache] 内容变了, 重建", flush=True)
print(f"[plan] {len(allk)} 条, 已有 {have}", flush=True)
t0 = time.time()
for i in range(have, len(allk)):
    vecs.append(lastphi(allk[i]))
    if (i + 1) % 30 == 0:
        el = time.time() - t0; n = i + 1 - have
        print(f"  {i+1}/{len(allk)}  {el:.0f}s  剩余约 {el/max(n,1)*(len(allk)-i-1):.0f}s", flush=True)
    if (i + 1) % 90 == 0:
        np.savez(CACHE, texts=np.array(allk[:i+1]), v=np.stack(vecs))
V = np.stack(vecs).astype(np.float32)
np.savez(CACHE, texts=np.array(allk), v=V)
print(f"[done] {time.time()-t0:.0f}s", flush=True)

n = len(KEYS)
idx = {"key": slice(0, n), "A": slice(n, 2*n), "B": slice(2*n, 3*n)}
def top1(write, probe, li, mode):
    A_ = V[idx[write], li, :]; Q_ = V[idx[probe], li, :]
    norm2 = (A_ * A_).sum(1) + 1e-12
    S = Q_ @ A_.T                    # (n, n)
    if mode == "inj":
        S = S / norm2[None, :]
    else:
        S = S / (np.linalg.norm(A_, axis=1)[None, :] * np.linalg.norm(Q_, axis=1)[:, None] + 1e-12)
    hits = (np.argmax(S, 1) == np.arange(n)).sum()
    per = [int((np.argmax(S[k*30:(k+1)*30], 1) == np.arange(30)).sum()) for k in range(3)]
    return int(hits), per

print("\n写入        探测  层   读出      top1/90   cap/cur/lang")
for write, probe in (("key","key"),("key","A"),("key","B"),("A","B"),("A","A"),("key+A","B")):
    for li, L in enumerate(LAYERS):
        if write == "key+A":
            W = np.stack([V[idx["key"], li, :], V[idx["A"], li, :]], 1)   # (n, 2, F)
            Q_ = V[idx["B"], li, :]; hits = 0; per = [0,0,0]
            for k in range(n):
                s = np.concatenate([[(Q_[k] @ W[:, j, :].T) / ((W[:, j, :]**2).sum(1)+1e-12)
                                     for j in range(2)]], 0).sum(0)
                r = int((s > s[k]).sum()); hits += (r == 0)
            print(f"{write:10s} {probe:5s} {L:3d} inj      {hits:3d}/90   -/-/- (两 key 求和)")
            continue
        for mode in ("inj", "cos"):
            h, per = top1(write, probe, li, mode)
            print(f"{write:10s} {probe:5s} {L:3d} {mode:4s}     {h:3d}/90   {per[0]:2d}/{per[1]:2d}/{per[2]:2d}")
