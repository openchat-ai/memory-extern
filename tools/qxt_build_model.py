#!/data/data/com.termux/files/usr/bin/python3
"""Build a real QxT-weight model (Q1T/Q2T...): quantize ALL q8_0 weight tensors
with the QxT codec (lloyd codebook + per-block e7m0 log scale), decode back to
float, re-q8_0, write back into a copy of the q8_0 GGUF.  The container stays
q8_0 so llama-cli loads it; the weights ARE the QxT decoded values
(q8_0 re-code loss ~1e-6, negligible vs QxT distortion).

Vectorized per 256-block chunk.  bitwidth via argv[1] (default 1).
"""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_fidelity_scan as Q


def pack_batch(q, b):
    """(N,32) int codes 0..2^b-1 -> (N, 4b) bytes, 每元素 b bit LSB-first.
    Mirrors qxt pack(): code_i at stream bit i*b + bit."""
    N, el = q.shape
    bits = np.zeros((N, el * b), np.uint8)
    for bit in range(b):
        bits[:, np.arange(el) * b + bit] = (q >> bit) & 1
    return np.packbits(bits, axis=1, bitorder="little")


def unpack_batch(c, b):
    """(N,4b) bytes -> (N,32) int codes, 每元素 b bit LSB-first."""
    N = c.shape[0]
    el = 32
    bits = np.unpackbits(np.ascontiguousarray(c), axis=1, bitorder="little")
    bits = bits[:, :el * b].astype(np.int64)           # (N, el*b)
    q = np.zeros((N, el), np.int64)
    for bit in range(b):
        q += bits[:, bit:bit + el * b:b] * (1 << bit)  # stride b: element i at i*b+bit
    return q


def enc_block_batch(Wb, cb, b):
    """Wb (N,32): per block best of 17 e7m0 scales + per-element nearest code.
    Returns (scales (N,) u8, codes (N,4b) u8)."""
    N, _ = Wb.shape
    m = len(cb)
    ampl = np.abs(Wb).max(1)
    cbmax = float(np.abs(cb).max())
    dbase = np.maximum(ampl, 1e-12) / cbmax
    l = np.log2(dbase)
    center = np.clip(np.rint((l - Q.LOG_LO) / Q.SC_STEP).astype(np.int32), 0, 127)
    best_sc = np.zeros(N, np.int32); best_err = np.full(N, np.inf)
    best_q = np.zeros((N, 32), np.int32)
    for k in range(-8, 9):
        sc = center + k
        ok = (sc >= 0) & (sc <= 127)
        sc_ok = np.clip(sc, 0, 127)
        d = Q.scale_table()[sc_ok]                          # (N,)
        rec = cb[None, None, :] * d[:, None, None]          # (N,1,m) * (N,1,1)
        diff = np.abs(Wb[:, :, None] - rec)                 # (N,32,m)
        q = np.argmin(diff, axis=2).astype(np.int32)        # (N,32)
        err = np.min(diff, axis=2).max(1)                   # (N,)
        upd = ok & (err < best_err)
        best_sc = np.where(upd, sc_ok, best_sc)
        best_err = np.where(upd, err, best_err)
        upd_b = upd[:, None]
        best_q = np.where(upd_b, q, best_q)
    return best_sc.astype(np.uint8), pack_batch(best_q, b)


def quant_q8(f32):
    d = f32.max(1) / 127.0
    k = f32 / np.maximum(d, 1e-12)[:, None]
    qs = np.clip(np.rint(k).astype(np.int16), -127, 127).astype(np.int8)
    return d.astype(np.float16), qs


def main():
    b = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    tag = f"Q{b}T"
    src = sys.argv[2] if len(sys.argv) > 2 else "/data/data/com.termux/files/home/models/qwen3-0.6b-q8_0.gguf"
    base = os.path.splitext(os.path.basename(src))[0]
    dst = f"/data/data/com.termux/files/home/models/qxt/{base}-{tag}_lloyd.gguf"
    if not os.path.exists(dst):
        import shutil; shutil.copyfile(src, dst)
    raw = bytearray(open(src, "rb").read())
    kv, infos, data_start = M.read_gguf(src)
    bb = M.BLOCK_BYTES[M.GGML_TYPE_Q8_0]
    qk = M.BLOCK_ELEMS[M.GGML_TYPE_Q8_0]
    q8s = [t for t in infos if t.type == M.GGML_TYPE_Q8_0 and len(t.dims) >= 2
               and t.name != "token_embd.weight"]

    rng = np.random.default_rng(0)
    sample = []
    for t in q8s[:4]:
        nb_tot = int(np.prod(t.dims)) // qk
        nb = min(4096, max(1, nb_tot // 64))
        b0 = int(rng.integers(max(1, nb_tot - nb)))
        W = M.dequant_blocks(src, t, data_start, b0, nb).reshape(-1, qk)
        sample.append(W)
    train = np.concatenate(sample)[:200_000]
    cb = Q.lloyd_cb(train, b)
    print(f"{tag} lloyd codebook (b={b}) = {cb.round(4)}", flush=True)

    n_t = 0
    for t in q8s:
        n_elem = int(np.prod(t.dims)); nb_tot = n_elem // qk
        if nb_tot == 0: continue
        out = bytearray()
        for b0 in range(0, nb_tot, 256):
            nb = min(256, nb_tot - b0)
            W = M.dequant_blocks(src, t, data_start, b0, nb).reshape(-1, qk).astype(np.float64)
            s, c = enc_block_batch(W, cb, b)
            Wdec = Q.scale_table()[s.astype(np.int64)][:, None] * cb[unpack_batch(c, b)]
            d, qs = quant_q8(Wdec)
            blk = np.empty((nb, 2 + 32), np.uint8)
            blk[:, 0:2] = d.astype(np.float16).view(np.uint8).reshape(-1, 2)
            blk[:, 2:] = qs.astype(np.uint8).reshape(nb, 32)
            out += blk.tobytes()
        off = data_start + int(t.offset)
        raw[off:off + len(out)] = out
        n_t += 1
        print(f"  [{n_t:3d}/{len(q8s)}] {t.name}  {nb_tot}/32blk", flush=True)
    open(dst, "wb").write(bytes(raw))
    print(f"wrote {dst} ({n_t} tensors, {tag} lloyd)")

if __name__ == "__main__":
    main()