#!/data/data/com.termux/files/usr/bin/python3
"""qxt_sens_scan.py — 混合精度: 张量敏感度测量 (激活加权).

敏感度定义: 张量 W 的量化误差经**真实激活**加权后, 对该层输出的影响.
  delta = || X @ (Wq - W)^T || / || X @ W^T ||
其中 X 是该层实际收到的激活 (用真实 prompt 前向一遍采集).

这个度量比裸 rel 误差更贴近模型行为 —— 一个 rel 0.3 但激活值很小的张量
对输出影响可以忽略. 混合精度应按 delta 而非 rel 分配 bit.

同时给出"保留哪些张量为 4bit"的贪心选择 (按 delta 从大到小, 看还剩多少).

用法: PYTHONPATH=tools python3 tools/qxt_sens_scan.py [n_layers]
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
from q1t_stream import StreamEngine, rmsnorm, apply_rope, read_packslim, SC_TAB

SRC = ("/data/data/com.termux/files/home/models/"
       "rStar-Coder-Qwen3-0.6B.Q8_0.gguf")
SLIM = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q{b}T_packslim.gguf")
QK = 32


def deq_slim(path, meta, by, name):
    """slim 张量 -> (n_out, n_in) float32."""
    e = by[name]
    n_in, n_out = e["dims"]
    nb = n_in * n_out // QK
    cb = np.array(meta["codebook"], np.float32)
    bb = meta["block_bytes"]
    nbits = (bb - 1) * 8 // QK
    with open(path, "rb") as f:
        f.seek(e["offset"])
        buf = np.frombuffer(f.read(nb * bb), np.uint8).reshape(-1, bb)
    sc = SC_TAB[buf[:, 0].astype(np.int64)]
    bits = np.unpackbits(np.ascontiguousarray(buf[:, 1:]), axis=1,
                         bitorder="little")[:, :QK * nbits]
    code = np.zeros((nb, QK), np.int64)
    for k in range(nbits):
        code |= bits[:, np.arange(QK) * nbits + k].astype(np.int64) << k
    return (sc[:, None] * cb[code]).astype(np.float32).reshape(n_out, n_in)


def collect_activations(E, toks, n_layer):
    """前向采集每层 attn 入口 / ffn 入口 / ffn_down 入口(门控后 3072维)的激活."""
    acts = {}
    nh, nkv, hd = E.n_head, E.n_kv, E.hd
    rep = nh // nkv
    T = len(toks)
    cos, sin = E.cos[:T], E.sin[:T]
    x = E._embed(list(toks))
    for i in range(n_layer):
        p = f"blk.{i}."
        h = rmsnorm(x, E.norm[p + "attn_norm.weight"], E.eps)
        acts[p + "attn"] = h.copy()
        q = rmsnorm(E.mat[p + "attn_q.weight"].matmul(h).reshape(-1, nh, hd),
                    E.norm[p + "attn_q_norm.weight"], E.eps)
        kk = rmsnorm(E.mat[p + "attn_k.weight"].matmul(h).reshape(-1, nkv, hd),
                     E.norm[p + "attn_k_norm.weight"], E.eps)
        vv = E.mat[p + "attn_v.weight"].matmul(h).reshape(-1, nkv, hd)
        q = apply_rope(q, cos, sin, np.arange(T))
        kk = apply_rope(kk, cos, sin, np.arange(T))
        sc = np.einsum("qhd,khd->hqk", q, np.repeat(kk, rep, 1)) / np.sqrt(hd)
        sc = np.where(np.triu(np.ones((T, T), bool), 1)[None], -1e9, sc)
        pr = np.exp(sc - sc.max(-1, keepdims=True))
        pr /= pr.sum(-1, keepdims=True)
        att = np.einsum("hqk,khd->qhd", pr,
                        np.repeat(vv, rep, 1)).reshape(-1, nh * hd)
        # attn_output 的输入是 attention 拼接输出 (n_out=nh*hd=2048)
        acts[p + "attnout"] = att.copy()
        x = x + E.mat[p + "attn_output.weight"].matmul(att)
        h = rmsnorm(x, E.norm[p + "ffn_norm.weight"], E.eps)
        acts[p + "ffn"] = h.copy()
        g = E.mat[p + "ffn_gate.weight"].matmul(h)
        u = E.mat[p + "ffn_up.weight"].matmul(h)
        gu = g / (1 + np.exp(-g)) * u           # ffn_down 的输入 (3072维)
        acts[p + "ffndown"] = gu.astype(np.float32)
        x = x + E.mat[p + "ffn_down.weight"].matmul(gu)
    return acts


def main():
    n_layer = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    E = StreamEngine(slim=SLIM.format(b=4))
    toks = np.array([151644]
                    + E.encode("You are Qwen3. You are a helpful assistant. /no_think")
                    + [151645, 151644] + E.encode("user\n1+1=?")
                    + [151645, 151644] + E.encode("assistant\n"), np.int64)

    t0 = time.time()
    acts = collect_activations(E, toks, n_layer)
    print(f"采集前 {n_layer} 层激活 ({len(toks)} token) {time.time()-t0:.1f}s\n")

    metas, bys = {}, {}
    for b in (2, 3, 4):
        metas[b], bys[b] = read_packslim(SLIM.format(b=b))
    src_kv, src_infos, src_ds = M.read_gguf(SRC)
    src_by = {t.name: t for t in src_infos}

    # 每个张量: 输入激活是谁 (attn_q/k/v/out 用 attn 入口; ffn_* 用 ffn 入口)
    def act_for(name):
        parts = name.split(".")
        p = f"{parts[0]}.{parts[1]}."          # "blk.0."
        kind = parts[2]                        # attn_q / ffn_down / ...
        if kind == "ffn_down":
            return acts[p + "ffndown"]
        if kind == "attn_output":
            return acts[p + "attnout"]
        if kind.startswith("ffn"):
            return acts[p + "ffn"]
        return acts[p + "attn"]

    rows = []
    print("%-32s %-8s %-10s %-10s %-10s" %
          ("张量", "rel(Q2)", "Δ(Q2)", "rel(Q3)", "Δ(Q3)"))
    print("-" * 76)
    for i in range(n_layer):
        for nm, info in src_by.items():
            if not nm.startswith(f"blk.{i}."):
                continue
            if info.type != M.GGML_TYPE_Q8_0 or len(info.dims) < 2:
                continue
            if nm == "token_embd.weight":
                continue
            n_in, n_out = info.dims
            nb = n_in * n_out // QK
            W = M.dequant_blocks(SRC, info, src_ds, 0, nb).astype(np.float32)
            W = W.reshape(n_out, n_in)                 # (n_out, n_in)
            X = act_for(nm).astype(np.float32)         # (T, n_in)
            base = X @ W.T
            nb_ = float(np.linalg.norm(base))
            out = []
            for b in (2, 3):
                Wq = deq_slim(SLIM.format(b=b), metas[b], bys[b], nm)  # (n_out,n_in)
                dW = Wq - W
                rel = float(np.linalg.norm(dW) / np.linalg.norm(W))
                dl = float(np.linalg.norm(X @ dW.T) / max(nb_, 1e-9))
                out.append((rel, dl))
            rows.append((out[0][1], out[1][1], nm, out[0][0], out[1][0]))

    rows.sort(reverse=True)
    for d2, d3, nm, r2, r3 in rows:
        print("%-32s %-8.4f %-10.5f %-10.4f %-10.5f" % (nm, r2, d2, r3, d3))

    # 按张量类型聚合
    print("\n=== 按张量类型聚合 (Δ = 激活加权相对输出误差) ===")
    kinds = {}
    for d2, d3, nm, r2, r3 in rows:
        k = nm.split(".")[-2]
        kinds.setdefault(k, []).append((d2, d3))
    print("%-16s %-10s %-10s" % ("类型", "Δ(Q2)", "Δ(Q3)"))
    for k, v in sorted(kinds.items(), key=lambda kv: -np.mean([x[0] for x in kv[1]])):
        print("%-16s %-10.5f %-10.5f" % (k, np.mean([x[0] for x in v]),
                                          np.mean([x[1] for x in v])))


if __name__ == "__main__":
    main()