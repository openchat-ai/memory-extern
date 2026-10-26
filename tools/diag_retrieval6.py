"""§10.34 分属性精度 + 层权重微调 (缓存, 无前向)."""
import numpy as np
z = np.load("/data/data/com.termux/files/home/sram/data/retr_real.npz")
V = z["v"]; Q = z["qv"]
POOL = ("France Japan Egypt Peru Brazil Chile China Spain Italy Greece Kenya Nepal "
        "Qatar Oman India Canada Mexico Norway Sweden Poland Turkey Iran Iraq Cuba "
        "Ghana Mali Laos Fiji Tonga Malta").split()
ATTRS = ["capital", "currency", "language"]
NPOOL = len(POOL) * 3
def cos(A, q):
    return A @ q / (np.linalg.norm(A, axis=1) * np.linalg.norm(q) + 1e-12)
def run(w, tag):
    A = np.concatenate([V[:, 0, :], w * V[:, 1, :]], 1)
    qs = np.concatenate([Q[:, 0, :], w * Q[:, 1, :]], 1)
    per = {a: [0, 0] for a in ATTRS}; tot = 0
    for g in range(NPOOL):
        s = cos(A, qs[g]); r = int((s > s[g]).sum()); ok = (r == 0)
        a = ATTRS[g % 3]; per[a][0] += ok; per[a][1] += 1; tot += ok
    print(f"{tag:22s} 总 {tot}/{NPOOL}={tot/NPOOL*100:5.1f}%  " +
          "  ".join(f"{a} {per[a][0]}/{per[a][1]}" for a in ATTRS))
    return per
for w in (0.0, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0):
    run(w, f"L4 + {w}*L6")
# 只 L4, 但按属性看各自的分差
print("\n只 L4 的逐属性:")
run(0.0, "L4 only")
# 换一种融合: 两层的余弦取平均 (等价于归一化后 concat)
A4 = V[:,0,:]/ (np.linalg.norm(V[:,0,:],axis=1,keepdims=True)+1e-9)
A6 = V[:,1,:]/ (np.linalg.norm(V[:,1,:],axis=1,keepdims=True)+1e-9)
q4 = Q[:,0,:]/ (np.linalg.norm(Q[:,0,:],axis=1,keepdims=True)+1e-9)
q6 = Q[:,1,:]/ (np.linalg.norm(Q[:,1,:],axis=1,keepdims=True)+1e-9)
per = {a:[0,0] for a in ATTRS}; tot=0
for g in range(NPOOL):
    s = cos(A4,q4[g]) + cos(A6,q6[g]); r=int((s>s[g]).sum()); ok=(r==0)
    a=ATTRS[g%3]; per[a][0]+=ok; per[a][1]+=1; tot+=ok
print(f"{'cos4+cos6 平均':22s} 总 {tot}/{NPOOL}={tot/NPOOL*100:5.1f}%  " +
      "  ".join(f"{a} {per[a][0]}/{per[a][1]}" for a in ATTRS))
