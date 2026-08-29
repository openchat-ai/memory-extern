#!/usr/bin/env python3
"""
kda_tensor_decompose 的纯Python演示: 真实「分解→重构→验证h_in余弦」闭环。
无torch机器可跑, 验证方法论; torch机用主工具扫全模型真实权重。

用幂迭代求 top-k 左奇异向量 + 谱能量, 展示:
  * 低秩头结构矩阵能被压到秩≈真秩, 且余弦→1.0(近无损)
  * 满秩矩阵压到小秩则余弦低(满秩墙)
"""
import math, random

def rand(n, m, seed, scale=1.0):
    random.seed(seed)
    return [[random.gauss(0, 1) / math.sqrt(m) * scale for _ in range(m)] for _ in range(n)]

def matvec(A, x):
    return [sum(A[i][j] * x[j] for j in range(len(x))) for i in range(len(A))]
def dot(a, b): return sum(x * y for x, y in zip(a, b))
def norm(a): return math.sqrt(dot(a, a))
def transpose(A):
    n = len(A[0]) if A and A[0] else 0
    return [[A[i][j] for i in range(len(A))] for j in range(n)]

def cos(a, b):
    na, nb = norm(a), norm(b)
    return dot(a, b) / (na * nb) if na * nb > 0 else 0.0

def power_svd(W, rank, iters=80):
    """幂迭代求 W 的 top-rank 奇异值 + 左奇异向量(近似). 返回 (svals, Ucols)."""
    n, m = len(W), len(W[0])
    Wt = transpose(W)
    svals, Ucols = [], []
    M = [row[:] for row in W]
    for _ in range(rank):
        v = [random.gauss(0, 1) for _ in range(m)]
        for _ in range(iters):
            y = matvec(Wt, matvec(M, v))
            ny = norm(y)
            if ny > 0: v = [t / ny for t in y]
        u_raw = matvec(M, v); nu = norm(u_raw)
        if nu < 1e-12:
            svals.append(0.0); Ucols.append([0.0] * n); continue
        u = [t / nu for t in u_raw]
        # sigma = ||M^T u||
        wt = matvec(Wt, u)
        s = norm(wt)
        svals.append(s); Ucols.append(u)
        # deflate
        if s > 1e-12:
            vv = [t / s for t in wt]
            for i in range(n):
                Mi = M[i]
                for j in range(m):
                    Mi[j] -= s * u[i] * vv[j]
    return svals, Ucols

def run_case(name, W, H, HD, R, coords):
    """W: [H*HD, d] 头结构权重; 对给定 (keep, d_in_samples) 测余弦"""
    n = len(W)
    d = len(W[0])
    xs = [[random.gauss(0, 1) for _ in range(d)] for _ in range(4)]
    y_true = [matvec(W, x) for x in xs]
    print(f"\n=== {name} [{n} x {d}] (H={H},HD={HD},真秩R={R}) ===")
    svals, Ucols = power_svd(W, min((R if R is not None else n) + 2, n), iters=60)
    s2 = [s * s for s in svals]; tot = sum(s2)
    print("  奇异值谱: " + " ".join(f"{s:.2f}" for s in svals[:min(len(svals), 6)]) + ("" if len(svals)<=6 else " ..."))
    for keep in coords:
        # 用前 keep 个左奇异向量投影重构: approx = U_keep @ (U_keep^T y_true)
        # 直接在输出空间投影到 U_keep 张成的子空间
        Ukeep = [Ucols[i] for i in range(min(keep, len(Ucols)))]
        coss = []
        for y in y_true:
            # 投影 y -> Ukeep 子空间
            proj = [0.0] * n
            for u in Ukeep:
                c = dot(y, u)
                for i in range(n): proj[i] += c * u[i]
            coss.append(cos(y, proj) if norm(proj) > 0 else 0.0)
        cap = sum(s2[:min(keep, len(s2))]) / tot if tot > 0 else 1.0
        print(f"  keep={keep}: 捕获能量{cap:.1%}, h_in余弦={sum(coss)/len(coss):.3f}")

def main():
    random.seed(0)
    print("张量分解「判定→分解→重构→验证」闭环 (纯Python)")

    # 案例1: 低秩头结构(有共享公共基) -> 可压
    d, H, HD, R = 16, 4, 4, 3
    U = rand(R, d, 1)
    C = rand(H * HD, R, 2)
    W = [[sum(C[r_][k] * U[k][i] for k in range(R)) for i in range(d)] for r_ in range(H * HD)]
    run_case("低秩头结构(可压)", W, H, HD, R, coords=[1, 2, 3, 4])

    # 案例2: 随机满秩 -> 满秩墙
    random.seed(7)
    n = H * HD
    M = rand(n, d, 77, scale=1.0)
    run_case("随机满秩(满秩墙)", M, H, HD, None, coords=[1, 2, 3, 8])

    print("""
结论(读法):
- 低秩头结构: keep=真秩R 时余弦→1.0 => 张量分解可压到R维, 近无损(§13 出路)
- 随机满秩: keep=1/2/3 余弦低, 需接近全维才高 => 满秩墙(§12)
- K3真实权重属哪类: torch机用 kda_tensor_decompose.py --ckpt 扫全模型测绘""")

if __name__ == "__main__":
    main()
