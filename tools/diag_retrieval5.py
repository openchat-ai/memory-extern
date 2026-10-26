"""§10.34 缓存上的零成本改进: 中心化 / 逐属性去模板 / 层拼接 + 误差归因."""
import numpy as np
z = np.load("/data/data/com.termux/files/home/sram/data/retr_real.npz")
keys = [str(k) for k in z["keys"]]; V = z["v"]
qk = [str(k) for k in z["qkeys"]]; Q = z["qv"]
POOL = ("France Japan Egypt Peru Brazil Chile China Spain Italy Greece Kenya Nepal "
        "Qatar Oman India Canada Mexico Norway Sweden Poland Turkey Iran Iraq Cuba "
        "Ghana Mali Laos Fiji Tonga Malta").split()
ATTRS = ["capital", "currency", "language"]
ATTR = {"capital": ("The capital of {} is", "What city is the capital of {}?"),
        "currency": ("The currency of {} is", "What money is used in {}?"),
        "language": ("The language of {} is", "What tongue do people speak in {}?")}
NPOOL = len(POOL) * 3
# 每个 key 的 (国, 属性) 标签
klab = [(c, a) for c in POOL for a in ATTRS] + [(None, None)] * (len(keys) - NPOOL)
def cos(A, q):
    return A @ q / (np.linalg.norm(A, axis=1) * np.linalg.norm(q) + 1e-12)
def ev(A, qs, gi, tag):
    hits = 0; same_ent = 0; detail = []
    for g, q in zip(gi, qs):
        s = cos(A, q); rank = int((s > s[g]).sum()); hits += (rank == 0)
        if rank != 0:
            top = int(np.argmax(s))
            same_ent += (klab[top][0] == klab[g][0])
            detail.append((klab[g], klab[top], round(float(s[g]), 3), round(float(s[top]), 3)))
        # 找同国不同属性的最高分 key (诊断属性混淆)
    print(f"{tag:28s} top1 {hits}/{len(gi)} = {hits/len(gi)*100:5.1f}%"
          f"   错误中同实体 {same_ent}/{len(gi)-hits}")
    return detail
gi = list(range(NPOOL))
for li, L in enumerate((4, 6, 8)):
    A = V[:, li, :]; qs = Q[:, li, :]
    ev(A, qs, gi, f"L{L} raw")
    mu = A[:NPOOL].mean(0)
    ev(A - mu, qs - mu, gi, f"L{L} centered")
    # 逐属性去模板: 减去同模板 key 的均值
    B = A.copy()
    for a in ATTRS:
        idx = [i for i in range(NPOOL) if klab[i][1] == a]
        B[idx] -= B[idx].mean(0)
        for j, (g, q) in enumerate(zip(gi, qs)):
            if klab[g][1] == a:
                qs[j] = qs[j] - B[idx].mean(0) if False else qs[j]
    ev(B, qs, gi, f"L{L} attr-demeaned")
d = ev(V[:, 0, :], Q[:, 0, :], gi, "L4 raw (再看细节)")
print("\nL4 错误样例 (gold -> 命中, sim):")
for x in d[:10]: print("  ", x[0], "->", x[1], x[2], x[3])
# 层拼接 (各自 L2 归一化后拼)
for combo in [(0,1),(0,1,2)]:
    A = np.concatenate([V[:,i,:]/(np.linalg.norm(V[:,i,:],axis=1,keepdims=True)+1e-9) for i in combo],1)
    qs = np.concatenate([Q[:,i,:]/(np.linalg.norm(Q[:,i,:],axis=1,keepdims=True)+1e-9) for i in combo],1)
    ev(A, qs, gi, f"concat L{combo} normed")
    mu = A[:NPOOL].mean(0); ev(A-mu, qs-mu, gi, f"concat L{combo} normed+centered")
