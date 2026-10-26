"""§10.34 门控实验: 模型自身激活做赫布式检索, 有没有区分力?

正例 = 同一条事实的换词改写; 负例 = 同模板不同实体 (最难).
指标 AUC(正例相似度 > 负例相似度). 门槛 0.9, 不过就放弃.
"""
import sys, os, itertools
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from hebb_write import HebbWriter

# (key, 改写, 实体token在key里的词面) —— 实体用单词, 避免位置歧义
from retr_pairs import PAIRS
LAYERS = [6, 10, 14, 18, 22, 26]

def cos(a, b):
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

def auc(pos, neg):
    pos, neg = np.array(pos), np.array(neg)
    return float(((pos[:, None] > neg[None, :]).mean() + 0.5 * (pos[:, None] == neg[None, :]).mean()))

def pick(vecs, mode):
    if mode == "last":
        return vecs[-1]
    if mode == "mean":
        return vecs.mean(0)
    if mode == "entity":
        return vecs[ent_pos]
    raise ValueError(mode)

def main():
    H = HebbWriter()
    E = H.eng
    print(f"[load] {H.N} 层 d={H.d} F={H.F}", flush=True)
    K, Q = [], []
    for kp, qp, ent in PAIRS:
        kt = list(E.encode(kp)); qt = list(E.encode(qp))
        kr, kph = H.capture_vecs(np.array(kt, np.int64))
        qr, qph = H.capture_vecs(np.array(qt, np.int64))
        ids = E.encode(" " + ent)
        ent_pos = kt.index(ids[-1]) if ids[-1] in kt else max(0, len(kt) - 3)
        K.append((kr, kph, ent_pos, kt)); Q.append((qr, qph, qt))
        # 查询侧实体位置: 找同一 token id
        Q[-1] = (qr, qph, qt, kt.index(ids[-1]) if ids[-1] in kt else len(qt) - 3)

    print("\n层  池化     正例cos  负例cos    AUC")
    best = None
    for L in LAYERS:
        for mode in ("last", "mean"):
            for side in ("res", "phi"):
                pos, neg = [], []
                for i in range(len(PAIRS)):
                    qi = Q[i][0][L] if side == "res" else Q[i][1][L]
                    qv = pick(qi, mode)
                    for j in range(len(PAIRS)):
                        kj = K[j][0][L] if side == "res" else K[j][1][L]
                        kv = pick(kj, mode)
                        (pos if i == j else neg).append(cos(qv, kv))
                a = auc(pos, neg)
                print(f"{L:3d} {side:4s}/{mode:5s} {np.mean(pos):7.3f} {np.mean(neg):8.3f}  {a:.3f}")
                if best is None or a > best[0]:
                    best = (a, L, side, mode)
    print(f"\n最佳: AUC={best[0]:.3f}  layer={best[1]} {best[2]}/{best[3]}"
          f"  -> {'通过门控, 继续做索引' if best[0] >= 0.9 else '未达 0.9, 放弃这条路线'}")


if __name__ == "__main__":
    main()
