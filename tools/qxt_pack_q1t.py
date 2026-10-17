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


def enc_batch_b1(W, cbmax):
    """1-bit 专用编码: 闭式 L2 最优 scale, O(1)/块 (无 128 档扫描).

    1-bit 每元素只有 ±cbmax 两档, 重建 = scale * sign(w) * cbmax.
    固定 sign 后 L2 最优 scale 有闭式解 s* = |sum(sign(w)*w)| / 32;
    再在 s* 附近的 scale 表档位 (±2 档) 里取 L2 最优即可达到 float 极限
    (实测 rel=0.5994 vs float极限 0.5992, 优于 128 档全扫的 0.6001,
     且快 ~250 倍 —— 128 档扫描要 256 次比较/元素).
    """
    W = W.astype(np.float32)
    sg = np.where(W > 0, 1.0, -1.0)
    s_star = np.abs((sg * W).sum(1)) / W.shape[1]
    st = Q.scale_table().astype(np.float64)
    idx = np.clip(np.rint((np.log2(np.maximum(s_star, 1e-30) / cbmax)
                           - Q.LOG_LO) / Q.SC_STEP).astype(np.int32), 0, 127)
    cand = np.clip(idx[:, None] + np.arange(-2, 3)[None, :], 0, 127)
    d = st[cand]                                     # (N,5)
    err = ((d[:, :, None] * sg[:, None, :] * cbmax
            - W.astype(np.float64)[:, None, :]) ** 2).sum(2)
    sc = cand[np.arange(W.shape[0]), err.argmin(1)]
    qb = (W > 0).astype(np.uint8)                    # 0 -> -cbmax, 1 -> +cbmax
    bits = qb
    codes = np.packbits(bits, axis=1, bitorder="little")
    return sc.astype(np.uint8), codes


def enc_batch_vec(W, cb, b):
    """向量化 enc_block: W (N,32) -> (sc (N,) u8, codes (N,4b) u8).

    两遍法 (替代 O(N*17*32*2^b) 的四维暴力搜索, 快 ~200 倍):
      pass 1: 用 center scale (由 max|w|/cbmax 定) 选最近码字, 并按 L2 解析
              求出连续最优 scale* = <W,Q>/<Q,Q> (Q = 选中的码字值向量).
      pass 2: 把 scale* 映射到 128 档对数表, 局部 ±WIN 档; 对每档用二次式
              err(d) = <W,W> - 2d<W,Q> + d^2<Q,Q> 直接算 L2, 取最小档.
              (Q 固定时 err 对 d 是凸二次, 无需重新选码)

    判据用 L2 平方误差和: max-err 判据对低位宽明显选错 scale (实测同一 sign
    下 max-err 给 rel=0.76~0.94, L2 给 0.60~0.65, 而 1-bit float 极限 0.60).
    """
    WIN = 2
    cbmax = float(np.abs(cb).max())
    N = W.shape[0]
    W = W.astype(np.float32)
    cb32 = np.asarray(cb, np.float32)
    m = len(cb32)
    st = Q.scale_table().astype(np.float32)
    ampl = np.abs(W).max(1)
    ww = (W.astype(np.float64) ** 2).sum(1)
    d = np.maximum(ampl, 1e-12) / cbmax
    # iterate: 选码 -> 解析最优 scale -> 局部档位微调 -> 用该 scale 重新选码
    # b<=2 电平数少, 初始 scale 偏差会带偏选码 -> 多迭代几轮收敛
    n_iter = 4 if b <= 2 else 3
    for _ in range(n_iter):
        t = W / d[:, None]                               # 目标码字值
        q = np.clip(np.searchsorted(cb32, t), 1, m - 1)
        lo = cb32[q - 1]; hi = cb32[q]
        q = np.where(np.abs(W - lo * d[:, None])
                     <= np.abs(W - hi * d[:, None]), q - 1, q)
        Qv = cb32[q]                                      # (N,32)
        num = (W * Qv).sum(1)
        den = np.maximum((Qv * Qv).sum(1), 1e-20)
        idx = np.clip(np.rint((np.log2(np.maximum(num / den, 1e-20))
                               - Q.LOG_LO) / Q.SC_STEP).astype(np.int32), 0, 127)
        cand = np.clip(idx[:, None] + np.arange(-WIN, WIN + 1)[None, :], 0, 127)
        dc = st[cand]                                     # (N,NC)
        err = (ww[:, None] - 2.0 * dc * num[:, None] + dc * dc * den[:, None])
        best = err.argmin(1)
        idx = cand[np.arange(N), best]
        d = st[idx]
    qb = q
    sc = idx
    # 向量化打包: 每元素 b bit LSB-first (mirror qxt_build_model.pack_batch).
    bits = np.empty((N, 32 * b), np.uint8)
    for bit in range(b):
        bits[:, np.arange(32) * b + bit] = (qb >> bit) & 1
    codes = np.packbits(bits, axis=1, bitorder="little")   # (N,4b)
    return sc.astype(np.uint8), codes


def pack_tensor(path, info, ds, cb, b, out_f):
    n_in, n_out = info.dims
    qk = M.QK_MXFP4
    nb = int(n_in * n_out) // qk
    # 编码已 O(N*32) 化 (原 O(N*17*32*2^b)), chunk 只需考虑 dequant 内存
    chunk = {1: 4096, 2: 16384, 3: 16384, 4: 16384}.get(b, 16384)
    sh = out_f.tell()
    for b0 in range(0, nb, chunk):
        nbw = min(chunk, nb - b0)
        W = M.dequant_blocks(path, info, ds, b0, nbw).reshape(-1, qk)
        if b == 1:
            sc, cod = enc_batch_b1(W, float(np.abs(cb).max()))
        else:
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
    # b=1 走 enc_batch_b1 闭式解; b>=2 用 ±8 窗口 (实测 128 档全扫对 b>=2
    # 仅多 0~11%, 但慢 7.5 倍, 不划算)

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
                "block_bytes": 1 + 4 * b, "src": base, "n_tensors": len(tensors),
                "codebook": cb.tolist(), "tensors": tensors}
        jb = json.dumps(meta).encode("utf-8")
        f.write(jb)
        # 回填 JSON 长度到 offset 9 (magic 后), 数据从 offset 17 开始
        f.seek(9)
        f.write(len(jb).to_bytes(4, "little"))
        f.flush()
    print(f"wrote {dst}  {tot/1e6:.1f} MB  ({time.time()-t0:.1f}s)", flush=True)


if __name__ == "__main__":
    main()