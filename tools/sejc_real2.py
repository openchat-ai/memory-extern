#!/usr/bin/env python3
"""SEJC 原型 v2 —— 激活感知重建误差 (对齐 SVD-LLM 的 min|WX - W'X| 而非 min|W-W'|)

关键修正: 谱平的权重矩阵, 纯权重重建(W-W')误差大, 但在真实激活分布下
输出重建(WX - W'X)可能小得多 —— 用激活敏感度做秩截断标准。
"""
import struct
import numpy as np
import time

def load_full():
    with open("pim/fixture_mxfp4.bin", "rb") as f:
        hdr = struct.unpack("<iiiii", f.read(20))
        rows, pc, sc, width, group = hdr
        f.read(rows * pc)          # packed
        f.read(rows * sc)          # scales
        expected = f.read(rows * width * 4)
    return np.frombuffer(expected, dtype=np.float32).reshape(rows, width).copy()

def cos_sim(a, b):
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

def rel_err(a, b):
    return float(np.linalg.norm(a - b) / (np.linalg.norm(a) + 1e-12))

def main():
    W = load_full()                      # (64, 3584)
    n_embd, n_ff = W.shape
    print(f"真实专家权重: {W.shape}, M={n_embd}xN={n_ff}, 原始密度={(W!=0).mean()*100:.0f}%")

    # ---------- SVD ----------
    U, S, Vt = np.linalg.svd(W, full_matrices=False)
    print(f"谱: max_S={S[0]:.2f} 前5={S[:5].round(3)} 前16能量={(S[:16]**2).sum()/(S**2).sum()*100:.0f}%")

    # ---------- 激活感知: 多样校准输入 ----------
    rng = np.random.default_rng(0)
    # 真实 GEMV 输入: 激活通常是正偏/带outlier的高斯分布
    calib = {
        "gauss":   rng.standard_normal((n_ff, 256)).astype(np.float32),
        "skewed":  (rng.standard_normal((n_ff, 256)) + 2.0).astype(np.float32) * np.abs(rng.standard_normal((n_ff, 1))),
        "sparse":  rng.standard_normal((n_ff, 256)).astype(np.float32) * (rng.random((n_ff, 256)) < 0.3),
    }

    Y_full = {k: W @ X for k, X in calib.items()}

    print("\n=== 秩扫描: 激活感知误差(Pareto front 显示) ===")
    print(f"{'秩':>4} {'能源%':>6} {'权重rel_err':>11} | {'gauss':>8} {'skewed':>8} "
          f"{'sparse':>8}   b/w(@U8b)")

    for pct in [1.0, 0.8, 0.6, 0.5, 0.36, 0.25, 0.2, 0.15, 0.1]:
        r = max(1, int(round(n_embd * pct)))
        r = min(r, len(S))
        U_r, S_r, Vt_r = U[:, :r], S[:r], Vt[:r, :]
        W_rec = (U_r * S_r) @ Vt_r
        w_err = rel_err(W, W_rec)
        energy = (S_r**2).sum() / (S**2).sum()
        # 激活感知误差
        a_errs = []
        for k in calib:
            Yr = W_rec @ calib[k]
            a_errs.append(rel_err(Y_full[k], Yr))
        # 存储开销: U8(V量化) + S熵编码
        bits = r * (n_embd + n_ff) * 8 + r * 8
        bpp = bits / W.size
        print(f"{r:>4} {energy*100:>5.0f}% {w_err:>11.3e} | "
              f"{a_errs[0]:>8.3e} {a_errs[1]:>8.3e} {a_errs[2]:>8.3e}   {bpp:>6.2f}b/w")

    # ---------- 核心洞察: 权重误差 vs 激活误差 ----------
    print("\n=== 关键发现 ===")
    print("若激活误差显著小于权重误差 → 谱平是'假象', 低秩在激活域仍有效")
    print("若二者相当 → K3专家确实不可低秩压缩")

    # 对比: 单秩保留的奇异值贡献
    print("\n奇异值能量贡献(dB):")
    for i in [0,1,2,4,8,16,31,63]:
        print(f"  S[{i}]={S[i]:.2f}  累计能量={(S[:i+1]**2).sum()/(S**2).sum()*100:5.1f}%")

if __name__ == "__main__":
    main()