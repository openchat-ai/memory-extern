#!/data/data/com.termux/files/usr/bin/python3
"""qxt_struct_scan.py — 突破 qk=32 块限制的精度扫描.

qxt_budget_scan 的结论: 固定 qk=32 时, scale 比特数怎么调都只能省 bits,
无法提升精度 (b=2 最好 0.41 @ 2.19bit, 而现状 2.25bit 已是 0.43).
瓶颈是"每 32 权重共享 1 个 scale"。

本脚本扫描**改变块结构**的方向, 目标是在与现状**相同或更少**的 bit 预算下
把 rel 压下来. 扫描项:
  A. 更小的块 qk (8/16/32): scale 开销变大, 但幅度适配更准
  B. 块内**多 scale 分组** (组 16/8 元素各一个 scale), 块大小不变
  C. **感知量化**: 用激活统计给每列(输入通道)一个重要性, 把 scale 预算
     分给重要列 (AWQ 思路的简化版) —— 对角线 scale 不改块结构
  D. 上界参考: 逐元素 float scale (不可行, 仅看理论空间)
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M

SRC = ("/data/data/com.termux/files/home/models/"
       "rStar-Coder-Qwen3-0.6B.Q8_0.gguf")

CODEBOOK = {
    1: [-0.341882, 0.341882],
    2: [-0.671, -0.1975, 0.1975, 0.671],
    3: [-0.8747, -0.5379, -0.2952, -0.096,
        0.096, 0.2952, 0.5379, 0.8747],
    4: [-0.9507, -0.7162, -0.5412, -0.4022, -0.2895, -0.1919,
        -0.1059, -0.0353, 0.0353, 0.1059, 0.1919, 0.2895,
        0.4022, 0.5412, 0.7162, 0.9507],
}


def encode_rtn(W, cb, k_sc=8, lo=-12.0, hi=0.0):
    """单 scale L2-RTN. W (N,qk) -> (sc_idx, codes)."""
    N, qk = W.shape
    n_tab = 1 << k_sc
    tab = 2.0 ** (np.arange(n_tab) * (hi - lo) / (n_tab - 1) + lo)
    cbmax = float(np.abs(cb).max())
    d = np.maximum(np.abs(W).max(1), 1e-12) / cbmax
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
    return cand[np.arange(N), err.argmin(1)], q, tab


def decode(idx, q, cb, tab):
    return tab[idx][:, None] * cb[q]


def rel_of(G, W):
    return float(np.linalg.norm(G - W) / np.linalg.norm(W))


def sample(nb):
    kv, infos, ds = M.read_gguf(SRC)
    qk = M.QK_MXFP4
    out = []
    for nm in ("blk.0.attn_q.weight", "blk.0.ffn_down.weight",
               "blk.13.ffn_down.weight"):
        t = [x for x in infos if x.name == nm][0]
        W = M.dequant_blocks(SRC, t, ds, 0, nb).astype(np.float64).reshape(-1, qk)
        out.append((nm, W))
    return out


def main():
    nb = int(sys.argv[1]) if len(sys.argv) > 1 else 20000
    data = sample(nb)
    print(f"采样 {len(data)} 张量 x {nb} 块 (元素级 rel)\n")

    # 现状基线 (qk=32, 8bit scale)
    print("=== 基线: qk=32, 8bit scale ===")
    for b in (2, 3, 4):
        cb = np.array(CODEBOOK[b])
        r = []
        for _, W in data:
            idx, q, tab = encode_rtn(W, cb)
            r.append(rel_of(decode(idx, q, cb, tab), W))
        print("  b=%d  bit/权重=%.3f  rel=%.4f"
              % (b, (8 + 32 * b) / 32, np.mean(r)))

    # A. 更小的块
    print("\n=== A. 更小的块 qk (scale 8bit, 自适应域) ===")
    for qk in (8, 16, 32):
        for b in (2, 3, 4):
            cb = np.array(CODEBOOK[b])
            r = []
            for _, W in data:
                Ws = W.reshape(-1, qk) if qk < 32 else W
                hi = float(np.log2(np.abs(W).max() / np.abs(cb).max())) + 1
                lo = hi - 12.0
                idx, q, tab = encode_rtn(Ws, cb, 8, lo, hi)
                G = decode(idx, q, cb, tab)
                if qk < 32:
                    G = G.reshape(W.shape)
                r.append(rel_of(G, W))
            print("  qk=%2d b=%d  bit/权重=%.3f  rel=%.4f"
                  % (qk, b, (8 + qk * b) / qk, np.mean(r)))

    # B. 块内多 scale 分组 (块=32, 组 g 元素一个 scale)
    print("\n=== B. 块=32, 组内多 scale (每组一个 8bit scale) ===")
    for g in (32, 16, 8):
        for b in (2, 3, 4):
            cb = np.array(CODEBOOK[b])
            r = []
            for _, W in data:
                hi = float(np.log2(np.abs(W).max() / np.abs(cb).max())) + 1
                lo = hi - 12.0
                Ws = W.reshape(-1, g)
                idx, q, tab = encode_rtn(Ws, cb, 8, lo, hi)
                G = decode(idx, q, cb, tab).reshape(W.shape)
                r.append(rel_of(G, W))
            n_sc = 32 // g
            print("  组=%2d b=%d  bit/权重=%.3f  rel=%.4f"
                  % (g, b, (n_sc * 8 + 32 * b) / 32, np.mean(r)))

    # C. 上界: 逐元素 float scale
    print("\n=== C. 上界参考: 逐元素 float scale (不可行, 仅看空间) ===")
    for b in (2, 3, 4):
        cb = np.array(CODEBOOK[b])
        r = []
        for _, W in data:
            t = W / np.abs(cb).max()
            q = np.clip(np.searchsorted(cb, t), 1, len(cb) - 1)
            q = np.where(np.abs(W - cb[q - 1] * np.abs(cb).max())
                         <= np.abs(W - cb[q] * np.abs(cb).max()), q - 1, q)
            # 逐元素最近码 (无 scale 共享) = 纯码本量化上界
            Wq = np.abs(cb).max() * cb[q]
            r.append(rel_of(Wq, W))
        print("  b=%d (无 scale 共享, 每权重 %.0f bit)  rel=%.4f"
              % (b, b, np.mean(r)))

    # D. 感知量化: 每列(输入通道)重要性 -> 不等比特分配, 这里用最简形式:
    # 对高幅值列多给 scale 精度 (给它们更小的分组), 低幅值列共享更粗 scale
    print("\n=== D. 按列幅值分层的混合块 (敏感列独立 scale) ===")
    for b in (2, 3, 4):
        cb = np.array(CODEBOOK[b])
        r = []
        for _, W in data:
            colmax = np.abs(W).max(0)              # (32,) 每列最大幅值
            # 前 50% 敏感列 -> qk=16 双 scale; 后 50% -> qk=32 单 scale
            order = np.argsort(-colmax)
            sens = set(order[:16].tolist())
            G = np.empty_like(W)
            hi_s = float(np.log2(np.abs(W[:, list(sens)]).max()
                                 / np.abs(cb).max())) + 1
            lo_s = hi_s - 12.0
            Ws = W[:, list(sens)].reshape(-1, 16)
            idx, q, tab = encode_rtn(Ws, cb, 8, lo_s, lo_s + 12.0)
            G[:, list(sens)] = decode(idx, q, cb, tab).reshape(16, -1).T
            mask = [i for i in range(32) if i not in sens]
            hi = float(np.log2(np.abs(W[:, mask]).max()
                               / np.abs(cb).max())) + 1
            idx, q, tab = encode_rtn(W[:, mask], cb, 8, hi - 12.0, hi)
            G[:, mask] = decode(idx, q, cb, tab)
            r.append(rel_of(G, W))
        # bit: 敏感16列用 2 scale/16 = (16+16*2)/16... 算平均
        bits = (16 * (2 * 8 + 16 * b) + 16 * (8 + 32 * b)) / (32 * 32)
        print("  b=%d  bit/权重=%.3f  rel=%.4f" % (b, bits, np.mean(r)))


if __name__ == "__main__":
    t0 = time.time()
    main()
    print("\n(%.1fs)" % (time.time() - t0))