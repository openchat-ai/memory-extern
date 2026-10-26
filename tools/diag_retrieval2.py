"""§10.34 应用判据: 真实查询 vs 312 条干扰 key 的 top-1 命中率.

AUC 0.9 对应 N=1000 的 top-1 概率 ~0, 所以必须直接测 top-1.
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter
from retr_pairs import PAIRS

FAKE_C = ["Zorvath","Kestrel","Meldral","Quelzor","Nimfarn","Triskav","Bexhul","Dralosk"]
def decoy_keys():
    out = []
    for y in range(1900, 1925):
        out.append(f"The winner of the {y} FIFA World Cup is")
    for c in FAKE_C:
        out += [f"The capital of {c} is", f"The currency of {c} is", f"The language of {c} is"]
    for c in ("Chile","China","Peru","Spain","Italy","Greece","Kenya","Nepal","Qatar","Oman"):
        out += [f"The capital of {c} is", f"The currency of {c} is", f"The language of {c} is"]
    return out

def cos(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

H = HebbWriter(); E = H.eng
recs = []
for kp, qp, ent in PAIRS:
    kr, kph = H.capture_vecs(np.array(list(E.encode(kp)), np.int64))
    qr, qph = H.capture_vecs(np.array(list(E.encode(qp)), np.int64))
    recs.append((kr, kph, qr, qph))
dec = decoy_keys()
dvec = []
for k in dec:
    r, p = H.capture_vecs(np.array(list(E.encode(k)), np.int64))
    dvec.append((r, p))
print(f"[data] 真实 {len(recs)} 条, 干扰 {len(dec)} 条", flush=True)

for L, side, mode in ((26,"res","mean"), (22,"phi","mean"), (10,"phi","mean"), (6,"phi","mean")):
    def vec(x):
        v = x[0][L] if side=="res" else x[1][L]
        return v.mean(0) if mode=="mean" else v[-1]
    hits = 0
    ranks = []
    for i, (kr, kph, qr, qph) in enumerate(recs):
        qv = vec((qr, qph))
        scores = []
        for j, (r2, p2) in enumerate(dvec):
            scores.append((cos(qv, vec((r2, p2))), f"DECOY{j}"))
        for j, (kr2, kph2, _, _) in enumerate(recs):
            scores.append((cos(qv, vec((kr2, kph2))), f"REAL{j}"))
        scores.sort(reverse=True)
        rank = [k for _, k in scores].index(f"REAL{i}")
        ranks.append(rank)
        hits += (rank == 0)
    print(f"L={L:2d} {side}/{mode}: top1 {hits}/{len(recs)} = {hits/len(recs)*100:.0f}%"
          f"  中位rank {int(np.median(ranks))}  最好rank {min(ranks)}")
