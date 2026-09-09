#!/usr/bin/env python3
"""无损 SEJC 可行性探查 —— 探清 U/V/Σ 的熵特性, 对比 zipNN 对原始 W 的熵。

关键: 无损 SEJC 要赢 zipNN, 必须证明 SVD 分解后的 U/V/Σ 比原始 W 更可压缩(熵更低)。
空口没用, 直接在当前 K3 真实权重上量。
"""
import struct
from collections import Counter
import numpy as np

def load_full():
    with open("pim/fixture_mxfp4.bin", "rb") as f:
        hdr = struct.unpack("<iiiii", f.read(20))
        rows, pc, sc, width, group = hdr
        f.read(rows * pc); f.read(rows * sc)
        return np.frombuffer(f.read(rows * width * 4), dtype=np.float32).reshape(rows, width).copy()

def entropy(x):
    x = np.asarray(x)
    c = Counter(x.tolist()); n = len(x)
    return -sum((cnt/n)*np.log2(cnt/n) for cnt in c.values()) if n else 0.0

def fp_entropy_bits(M):
    """单精度浮点逐位熵: 分别算 符号/指数/尾数 的熵 (zipNN 的分法)"""
    flat = M.flatten().view(np.int32)
    sign = (flat >> 31) & 1
    exp  = (flat >> 23) & 0xFF
    mant = flat & 0x7FFFFF
    return entropy(sign), entropy(exp), entropy(mant), len(flat)

def main():
    W = load_full()
    n_embd, n_ff = W.shape
    print(f"真实权重: {W.shape}, 元素={W.size:,}")

    print("\n=== 原始 W (zipNN 基线) ===")
    s, e, m, n = fp_entropy_bits(W)
    total_w = n*(s+e+m)
    print(f"  sign={s:.2f}b  exp={e:.2f}b  mant={m:.2f}b → 每权重={s+e+m:.2f}b "
          f"({32/(s+e+m):.2f}x)")

    print("\n=== SVD 分解 U / Σ / V ===")
    U, S, Vt = np.linalg.svd(W, full_matrices=False)
    with np.printoptions(precision=3, suppress=True):
        print(f"  Σ 分布: 前8={S[:8]}")
        print(f"  Σ 范围: [{S.min():.3f}, {S.max():.3f}]  span={S.max()/max(S.min(),1e-9):.1f}")
    Uflat = np.ascontiguousarray(U).reshape(-1)
    Vflat = np.ascontiguousarray(Vt).reshape(-1)

    for name, M in [("U(64x64)", Uflat), ("Vt(64x3584)", Vflat), ("Σ(64)", S)]:
        s2, e2, m2, n2 = fp_entropy_bits(M)
        total = n2*(s2+e2+m2)
        print(f"  {name:<12} sign={s2:.2f} exp={e2:.2f} mant={m2:.2f} → 每元素={s2+e2+m2:.2f}b "
              f"({32/(s2+e2+m2):.2f}x), 合计={total/8/1e3:.0f}KB")

    # 整体无损 SEJC 总开销(U+V+Σ) vs 原始 W
    s2,e2,m2,n2 = fp_entropy_bits(np.ascontiguousarray(U).reshape(-1))
    su,eu,mu,nu = fp_entropy_bits(Uflat)
    sv,ev,mv,nv = fp_entropy_bits(Vflat)
    ss,es,ms,ns = fp_entropy_bits(S)
    total_sejc = nu*(su+eu+mu) + nv*(sv+ev+mv) + ns*(ss+es+ms)
    print(f"\n=== 无损 SEJC 总开销 ===")
    print(f"  U+V+Σ 总位 = {total_sejc:,.0f} → 等价 {total_sejc/n:.2f} b/w ({n*32/total_sejc:.2f}x)")
    print(f"  原始 W     = {total_w:,.0f} → 每权重 {s+e+m:.2f} b/w ({n*32/total_w:.2f}x)")
    lose = total_sejc / total_w
    print(f"  比值 SEJC/zipNN = {lose:.2f}  (>1 表示 SEJC 更差, <1 表示 SEJC 更优)")

if __name__ == "__main__":
    main()