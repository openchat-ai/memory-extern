#!/data/data/com.termux/files/usr/bin/python3
"""qxt_pack_q1t.py — 从 Q8_0 源生成"真无壳 Q1T" 文件, 供 q1t_engine 读取.

格式 (Q1T 内容最小落盘, 每 32 元素一块):
    { uint8 sc;        # scale_table 索引 (128级 log2 域)
      uint8 bit[4];    # 32×1bit lloyd 码本索引 (pack, LSB-first), cb=±a
    } = 5 字节 / 32 权重 = 1.25 bpw

向量化打包: 一次处理 1024×512 块, scale 搜索 17 档全部并行.
"""
import sys, os, json, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_fidelity_scan as Q

SRC = "/data/data/com.termux/files/home/models/rStar-Coder-Qwen3-0.6B.Q8_0.gguf"


def train_cb(path, b, max_blocks=25000, seed=1):
    kv, infos, ds = M.read_gguf(path)
    rng = np.random.default_rng(seed)
    samp = []
    for t in infos:
        if t.type != M.GGML_TYPE_Q8_0 or len(t.dims) < 2 or t.name == "token_embd.weight":
            continue
        nb_tot = int(np.prod(t.dims)) // M.QK_MXFP4
        if nb_tot < 64:
            continue
        take = min(64, max(1, nb_tot // 64))
        for i in range(take):
            b0 = int(rng.integers(0, nb_tot))
            w = M.dequant_blocks(path, t, ds, b0, 1).reshape(-1, M.QK_MXFP4)
            samp.append(w)
    W = np.concatenate(samp)
    print(f"[lloyd] 采样 {W.shape[0]} 块, seed={seed}", flush=True)
    return Q.lloyd_cb(W, b), W.shape[0]


def enc_batch_vec(W, cb, b):
    """向量化 enc_block: W (N,32) -> (sc (N,) u8, codes (N,4b) u8).
    对每块在 log2(ampl/cbmax) 中心±8 的 17 档 scale 全扫描, 取 max-err 最小."""
    cbmax = float(np.abs(cb).max())
    N = W.shape[0]
    ampl = np.abs(W).max(1)
    dbase = np.maximum(ampl, 1e-12) / cbmax
    l = np.log2(dbase)
    LOG_LO = Q.LOG_LO
    SC_STEP = Q.SC_STEP
    st = Q.scale_table().astype(np.float64)
    center = np.clip(np.rint((l - LOG_LO) / SC_STEP).astype(np.int32), 0, 127)
    # 17 candidate sc per block: center-8..center+8, clipped
    cand = center[:, None] + np.arange(-8, 9)[None, :]   # (N,17)
    ok = (cand >= 0) & (cand <= 127)
    candc = np.clip(cand, 0, 127)
    d = st[candc]                                         # (N,17)
    # rec = W 每块每档: cb[q] 选最近
    diff = np.abs(W[:, None, :, None] - d[:, :, None, None] * cb[None, None, None, :])  # (N,17,32,2)
    q = np.argmin(diff, axis=3)                            # (N,17,32)
    err = np.min(diff, axis=3).max(axis=2)                 # (N,17)
    best = np.where(ok, err, np.inf).argmin(axis=1)        # (N,)
    sc = candc[np.arange(N), best]
    qb = q[np.arange(N), best]                             # (N,32) 0/1
    codes = np.packbits(qb.astype(np.uint8), axis=1, bitorder="little")  # (N,4)
    return sc.astype(np.uint8), codes


def pack_tensor(path, info, ds, cb, b, out_f):
    n_in, n_out = info.dims
    qk = M.QK_MXFP4
    nb = int(n_in * n_out) // qk
    chunk = 32768
    sh = out_f.tell()
    for b0 in range(0, nb, chunk):
        nbw = min(chunk, nb - b0)
        W = M.dequant_blocks(path, info, ds, b0, nbw).reshape(-1, qk)
        sc, cod = enc_batch_vec(W, cb, b)
        blk = np.empty((nbw, 1 + 4 * b), np.uint8)
        blk[:, 0] = sc
        blk[:, 1:] = cod
        out_f.write(blk.tobytes())
    return out_f.tell() - sh


def main():
    b = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    src = sys.argv[2] if len(sys.argv) > 2 else SRC
    tag = f"Q{b}T"
    base = os.path.splitext(os.path.basename(src))[0]
    dst = f"/data/data/com.termux/files/home/models/qxt/{base}-{tag}_packslim.gguf"
    kv, infos, ds = M.read_gguf(src)

    cb, nsamp = train_cb(src, b)
    print(f"codebook (b={b}) = {cb.round(5)}", flush=True)

    t0 = time.time()
    tot = 0
    with open(dst, "wb") as f:
        f.write(b"QXTSLIM1\n")
        f.write(b"\0" * 8)
        tensors = []
        for t in infos:
            if t.type == M.GGML_TYPE_Q8_0 and len(t.dims) >= 2 and t.name != "token_embd.weight":
                off = f.tell()
                nbw = pack_tensor(src, t, ds, cb, b, f)
                tensors.append({"name": t.name, "dims": list(t.dims), "bytes": nbw,
                                "offset": off})
                tot += nbw
                print(f"  {len(tensors):3d} {t.name} {nbw/1e6:.1f}MB", flush=True)
        out_end = f.tell()
        meta = {"format": f"qxt-{tag}-slim", "bitwidth": b, "block_elems": 32,
                "block_bytes": 5, "src": base, "n_tensors": len(tensors),
                "tensors": tensors}
        jb = json.dumps(meta).encode("utf-8")
        f.write(jb)
        # 回填 JSON 长度到 offset 9 (magic 后), 数据从 offset 17 开始
        f.seek(9)
        f.write(len(jb).to_bytes(4, "little"))
        f.flush()
    print(f"wrote {dst}  {tot/1e6:.1f} MB  ({time.time()-t0:.1f}s)", flush=True)


if __name__ == "__main__":
    main()