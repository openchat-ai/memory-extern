#!/data/data/com.termux/files/usr/bin/python3
"""qxt_budget_scan.py — QxT 位宽/块结构的信息预算扫描.

问题: 当前格式 {u8 sc; bits[4b]} 每块32元素, 每权重耗 (8+4b)/32 bit.
  b=1 -> 1.25 bit -> rel 0.62 (已到理论极限)
  b=2 -> 1.50 bit -> rel 0.36   不可用
  b=3 -> 1.75 bit -> rel 0.18   不可用
  b=4 -> 2.00 bit -> rel 0.083  可用
本脚本扫描: 给定每权重 bit 预算, 怎么在 (码宽 b, 块大小 qk, scale 比特数 k,
是否双 scale) 之间分配最优, 给出 RTN(weight-only) 下的精度上界.

用法: PYTHONPATH=tools python3 tools/qxt_budget_scan.py [每张量采样块数]
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M

SRC = ("/data/data/com.termux/files/home/models/"
       "rStar-Coder-Qwen3-0.6B.Q8_0.gguf")

# 真实 scale 表 (打包端用): 2^-12 .. 2^0, 128 档
LOG_LO, LOG_HI, NSC = -12.0, 0.0, 128
SC_TAB = (2.0 ** (np.arange(NSC) * (LOG_HI - LOG_LO) / (NSC - 1) + LOG_LO)
          ).astype(np.float64)


def rtn_encode(W, cb, k_sc_bits=8, lo=LOG_LO, hi=LOG_HI):
    """单 scale RTN: 返回 (sc_idx, codes), codes 为 cb 的下标 (N, qk).

    k_sc_bits: scale 指数比特数; lo/hi: scale 对数范围 (自适应时按张量给).
    """
    N, qk = W.shape
    n_tab = 1 << k_sc_bits
    tab = (2.0 ** (np.arange(n_tab) * (hi - lo) / (n_tab - 1) + lo))
    cbmax = float(np.abs(cb).max())
    ampl = np.abs(W).max(1)
    d = np.maximum(ampl, 1e-12) / cbmax
    t = W / d[:, None]
    q = np.clip(np.searchsorted(cb, t), 1, len(cb) - 1)
    q = np.where(np.abs(W - cb[q - 1] * d[:, None])
                 <= np.abs(W - cb[q] * d[:, None]), q - 1, q)
    idx = np.clip(np.rint((np.log2(np.maximum(d, 1e-30)) - lo)
                          / ((hi - lo) / (n_tab - 1))).astype(np.int32),
                  0, n_tab - 1)
    cand = np.clip(idx[:, None] + np.arange(-2, 3)[None, :], 0, n_tab - 1)
    dc = tab[cand]
    Qv = cb[q]
    num = (W * Qv).sum(1)
    den = np.maximum((Qv * Qv).sum(1), 1e-20)
    ww = (W ** 2).sum(1)
    err = ww[:, None] - 2 * dc * num[:, None] + dc * dc * den[:, None]
    return cand[np.arange(N), err.argmin(1)], q


def rtn_decode(idx, q, cb, k_sc_bits=8, lo=LOG_LO, hi=LOG_HI):
    n_tab = 1 << k_sc_bits
    tab = (2.0 ** (np.arange(n_tab) * (hi - lo) / (n_tab - 1) + lo))
    return tab[idx][:, None] * cb[q]


def split_blocks(W, qk):
    """(N,qk_big) -> (N*qk_big//qk, qk) 列块拆分, 每行独立成块."""
    N, big = W.shape
    if big == qk:
        return W
    return W.reshape(-1, qk)


def sample_tensors(nb_blocks):
    kv, infos, ds = M.read_gguf(SRC)
    qk = M.QK_MXFP4
    out = []
    for nm in ("blk.0.attn_q.weight", "blk.0.ffn_down.weight",
               "blk.13.ffn_down.weight", "blk.27.attn_q.weight"):
        t = [x for x in infos if x.name == nm][0]
        W = M.dequant_blocks(SRC, t, ds, 0, nb_blocks).astype(np.float64)
        W = W.reshape(-1, qk)
        out.append((nm, W, float(np.abs(W).max())))
    return out


# 各 bit 宽的 Lloyd 码本 (与打包端一致, 升序)
CODEBOOK = {
    1: [-0.341882, 0.341882],
    2: [-0.671, -0.1975, 0.1975, 0.671],
    3: [-0.8747, -0.5379, -0.2952, -0.096,
        0.096, 0.2952, 0.5379, 0.8747],
    4: [-0.9507, -0.7162, -0.5412, -0.4022, -0.2895, -0.1919,
        -0.1059, -0.0353, 0.0353, 0.1059, 0.1919, 0.2895,
        0.4022, 0.5412, 0.7162, 0.9507],
}


def bitcost(qk, k_sc_bits, b, n_group=1):
    """每权重比特数 = (n_group*k_sc_bits + qk*b) / qk"""
    return (n_group * k_sc_bits + qk * b) / qk


def main():
    nb = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    data = sample_tensors(nb)
    print(f"采样 {len(data)} 张量 x {nb} 块 (块=32元素)\n")

    rows = []
    # --- 1) 现状: qk=32, k_sc=8, 固定 scale 域 [2^-12,2^0] ---
    for b in (1, 2, 3, 4):
        cb = np.array(CODEBOOK[b])
        rels = []
        for _, W, _ in data:
            idx, q = rtn_encode(W, cb, 8)
            G = rtn_decode(idx, q, cb, 8)
            rels.append(np.linalg.norm(G - W) / np.linalg.norm(W))
        rows.append((bitcost(32, 8, b), 32, 8, 1, b, float(np.mean(rels)),
                     "现状"))

    # --- 2) 自适应 scale 域 (按张量 max 定 hi), k_sc 可降到 5-6 bit ---
    for k_sc in (5, 6, 7, 8):
        for b in (1, 2, 3, 4):
            cb = np.array(CODEBOOK[b])
            rels = []
            for _, W, wmax in data:
                hi = float(np.log2(wmax / np.abs(cb).max())) + 1
                lo = hi - 12.0
                idx, q = rtn_encode(W, cb, k_sc, lo, hi)
                G = rtn_decode(idx, q, cb, k_sc, lo, hi)
                rels.append(np.linalg.norm(G - W) / np.linalg.norm(W))
            rows.append((bitcost(32, k_sc, b), 32, k_sc, 1, b,
                         float(np.mean(rels)), f"自适应域"))

    # --- 3) 双 scale: 块内分 2 组各一个 scale ---
    for k_sc in (6, 8):
        for b in (1, 2, 3, 4):
            cb = np.array(CODEBOOK[b])
            rels = []
            for _, W, wmax in data:
                W2 = split_blocks(W, 16)          # 16 元素/组
                hi = float(np.log2(wmax / np.abs(cb).max())) + 1
                lo = hi - 12.0
                idx, q = rtn_encode(W2, cb, k_sc, lo, hi)
                G = rtn_decode(idx, q, cb, k_sc, lo, hi)
                Gh = G.reshape(W.shape)          # (N/2,16) -> (N,32)
                rels.append(np.linalg.norm(Gh - W) / np.linalg.norm(W))
            rows.append((bitcost(32, k_sc, b, 2), 32, k_sc, 2, b,
                         float(np.mean(rels)), "双scale(组16)"))

    rows.sort(key=lambda r: (r[0], r[5]))
    print("%-9s %-6s %-6s %-7s %-4s %-9s %s"
          % ("bit/权重", "qk", "sc_bit", "组数", "b", "rel", "方案"))
    for c, qk, k, g, b, rel, tag in rows:
        print("%-9.3f %-6d %-6d %-7d %-4d %-9.4f %s"
              % (c, qk, k, g, b, rel, tag))

    # --- 4) 定点: 相同 bit 预算下最优方案 ---
    print("\n=== 相同 bit 预算下的最优分配 (RTN 上界) ===")
    budgets = sorted({round(r[0], 3) for r in rows})
    for bud in budgets:
        cand = [r for r in rows if abs(r[0] - bud) < 1e-3]
        best = min(cand, key=lambda r: r[5])
        cur = [r for r in cand if r[6] == "现状"]
        c = (f"{bud:.3f} bit: 最优 rel={best[5]:.4f} "
             f"(qk={best[1]},sc={best[2]}bit,组{best[3]},b={best[4]})")
        if cur:
            c += f"  | 现状 rel={cur[0][5]:.4f}"
        print(c)


if __name__ == "__main__":
    t0 = time.time()
    main()
    print(f"\n({time.time()-t0:.1f}s)")