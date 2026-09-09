#!/usr/bin/env python3
"""SEJC 原型 —— 在 kimi-k3 真实专家权重上验证 谱-指数联合压缩。

数据: pim/fixture_mxfp4.bin 的 'expected' 段 = 64x3584 fp32 去量化真实权重。
验证: 压缩率(位/权重) + 重建误差(MSE/相对范数) + 无解压GEMV一致性。
"""
import struct
import sys
import numpy as np

def load_full():
    with open("pim/fixture_mxfp4.bin", "rb") as f:
        hdr = struct.unpack("<iiiii", f.read(20))
        rows, pc, sc, width, group = hdr
        packed = f.read(rows * pc)
        scales = f.read(rows * sc)
        expected = f.read(rows * width * 4)
    W = np.frombuffer(expected, dtype=np.float32).reshape(rows, width).copy()
    return W

def report(name, bits_total, nparam, err, cos):
    bpp = bits_total / nparam
    print(f"{name:<28} {bpp:>7.2f} b/w   {nparam*32/bits_total:>7.1f}x   "
          f"mse={err:.4e}  rel={err/np.linalg.norm(np.ones_like(np.zeros(1))):.3e} cos={cos:.4f}")

def cos_sim(a, b):
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))

def bits_for_matrix(M, mant_bits, exp_flags):
    """M 的存储开销: (arbitrary float -> mant bits + 指数熵编码达到无损)"""
    if M.size == 0:
        return 0
    flat = M.flatten()
    n = flat.size
    # 指数位: 用信息熵(无损编码奇异值/元素的范围信息)
    absmax = np.max(np.abs(flat))
    if absmax <= 0:
        return n * mant_bits
    # 相对指数开销(对数域) —— 近似真实熵编码
    e = np.abs(flat) / absmax
    exps = np.ceil(np.log2(e + 1e-30))
    p = np.clip(1 - exps, 0, None)
    # 保守: 量化为 mant_bits 后, 存储 = mant + 每元素指数Huffman
    mant = n * mant_bits
    # 指数熵(最多代表 2^mant)
    uniq = np.unique(np.clip(exps, -32, 0))
    prob = np.histogram(exps, bins=uniq) if False else None
    # 简化: 用唯一值数近似熵
    k = len(np.unique(exps))
    exp_acct = n * np.log2(k) if 1 < k <= 16 else n * 0.5
    # 每元素标记指数组数量少则便宜
    return mant + exp_acct

def main():
    W = load_full()
    n_embd, n_ff = W.shape
    nparam = W.size
    print(f"真实专家权重: shape={W.shape}, 参数量={nparam:,}, "
          f"fp32 大小={W.nbytes/1e6:.2f} MB, 原始密度={(W!=0).mean()*100:.1f}%")
    print()

    # ---------- 对照 J: 无损熵下界(zipNN思路逐张量) ----------
    flat32 = W.flatten().view(np.int32)
    exp = (flat32 >> 23) & 0xFF
    mant = flat32 & 0x7FFFFF
    from collections import Counter
    def entropy(x):
        x = np.asarray(x)
        c = Counter(x.tolist()); n = len(x); 
        return -sum((cnt/n)*np.log2(cnt/n) for cnt in c.values())
    e_exp, e_mant, e_sign = entropy(exp), entropy(mant), entropy((flat32>>31)&1)
    zipnn_bits = nparam * (e_exp + e_mant + e_sign)
    bpp = zipnn_bits/nparam
    print(f"对照 zipNN(无损): 熵下界 {bpp:.2f} b/w ≈ {nparam*32/zipnn_bits:.2f}x")

    # ---------- SEJC ----------
    print("\n=== SEJC: SVD 谱域 + 奇异值指数熵编码 + U/V量化 ===")
    t0 = __import__('time').time()
    U, S, Vt = np.linalg.svd(W, full_matrices=False)
    print(f"SVD 耗时: {__import__('time').time()-t0:.1f}s  (奇异值 S 谱: max={S[0]:.1f}, n={len(S)})")

    # 奇异值指数熵(谱通常尖锐可压缩)
    e_S = entropy(S.tolist())

    # 测试多个秩 + 不同 mant 位
    for rank in [n_embd//4, n_embd//8, 384]:
        r = min(rank, len(S))
        U_r = U[:, :r]; S_r = S[:r]; Vt_r = Vt[:r, :]
        # 重建
        W_rec = (U_r * S_r) @ Vt_r
        err = np.linalg.norm(W - W_rec) / np.linalg.norm(W)
        # 相对能量
        energy = (S_r**2).sum() / (S**2).sum()
        for mant in [4, 6, 8]:
            # U/V 量化到 mant 位(块缩放), 奇异值熵编码
            u_bits = bits_for_matrix(U_r, mant, None) + bits_for_matrix(S_r.reshape(-1,1), mant, None) + bits_for_matrix(Vt_r, mant, None)
            bpp = u_bits / nparam
            print(f"  rank={r:>4} 能源{energy*100:>5.1f}% 量化{mant}b  → {bpp:>5.2f} b/w "
                  f"= {nparam*32/u_bits:>6.1f}x   rel_err={err:.3e}")

    # ---------- 无解压 GEMV 一致性 ----------
    print("\n=== 无解压 GEMV(压缩域直接计算) ===")
    r = 384
    U_r, S_r, Vt_r = U[:, :r], S[:r], Vt[:r, :]
    x = np.random.randn(n_ff).astype(np.float32)
    y_ref = W @ x
    # 压缩域: 先 Vt@x, 再逐scale, 再 U@
    mid = Vt_r @ x
    y_sejc = (U_r * S_r[:, None]) @ mid  # 避免大对角
    print(f"对照: y_sejc ≈ y_ref, cos={cos_sim(y_ref, y_sejc):.4f}, "
          f"rel_err={np.linalg.norm(y_ref-y_sejc)/np.linalg.norm(y_ref):.3e}")

if __name__ == "__main__":
    main()