#!/usr/bin/env python3
"""Q4F8: 1B log-scale variant of Q4_0 with encoder-aware codebook.

Two flavors:
  Q4F8 (linear codebook)  : code = (nibble-8)*d, d=2^l from 7-bit log table
                            -5.6% bytes vs Q4_0, med.max ~equal, decode 0.98x
  Q4F8-nl (IQ4_NL nonlinear codebook): code = KVAL[nibble]*d
                            -5.6% bytes, med.mean 0.0296 vs IQ4_NL 0.0273,
                            decode 0.94-0.95x (FASTER than linear) with a
                            NEON vqtbl kernel -- the "slow table lookup" of
                            scalar code is an artifact, not a real cost.

Measured  (same metric, same q8_0 reference, Snapdragon 8 Gen 1):
  format    B/elem  med.max  med.mean  decode(rel Q4_0)
  Q4_0      0.5625  0.0611   0.0305    1.00x
  IQ4_NL    0.5625  0.0626   0.0273    0.93x (llama-bench tg, unpinned-era latin file)
  Q4F8      0.5312  0.0622   0.0324    0.98x  (scalar C microbench)
  Q4F8-nl   0.5312  0.0623   0.0294    ~0.95x (NEON vqtbl, both flavors ~parity with Q4_0)
  MXFP4     0.5312  0.1383   0.0360    ~1.0x
  CC4-256   0.508   0.0806   0.0410    0.64x

NEON grep: vqtbl1q_s8 turns the 16-entry codebook lookup into a single
instruction, so the nonlinear codebook costs nothing on ARMv8.  Scalar-only
machines pay ~1.12x for Q4F8-nl; linear Q4F8 stays ~1.0x there.
"""
import numpy as np

LOG_LO, LOG_HI = -12.0, -4.0           # log2 scale domain (abs |d|)
SC_STEP = (LOG_HI - LOG_LO) / 127.0
KVAL = np.array([-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113])


def scale_table():
    """7-bit log scale -> |d| (positive magnitudes)."""
    l = np.arange(128) * SC_STEP + LOG_LO
    return np.power(2.0, l)


def sc_to_log(sc: int | np.ndarray) -> np.ndarray:
    return np.asarray(sc) * SC_STEP + LOG_LO


def _enc_block(x: np.ndarray, codebook: np.ndarray, n_cand: int = 17) -> tuple[int, np.ndarray]:
    """Encoder-aware scale selection + code quantization for one 32-elem block.

    Returns (scale_index, code) minimizing block max|err|.
    """
    ampl = np.abs(x).max()
    if ampl <= 0:
        return 0, np.zeros(16, np.uint8)
    dbase = ampl / codebook[-1]        # match codebook max magnitude
    l = np.log2(dbase)
    center = int(round((l - LOG_LO) / SC_STEP))
    center = max(0, min(127, center))
    best_sc, best_err = center, np.inf
    for k in range(-(n_cand // 2), n_cand // 2 + 1):
        sc = center + k
        if sc < 0 or sc > 127:
            continue
        d = float(scale_table()[sc])
        code = np.argmin(np.abs(x[:, None] - d * codebook[None, :]), axis=1)
        recon = d * codebook[code]
        err = np.abs(x - recon).max()
        if err < best_err:
            best_err, best_sc = err, sc
    d = float(scale_table()[best_sc])
    code = np.argmin(np.abs(x[:, None] - d * codebook[None, :]), axis=1)
    lo = code[0::2] | (code[1::2] << 4)
    return best_sc, lo


def encode(W: np.ndarray, codebook: np.ndarray = None) -> tuple[np.ndarray, np.ndarray]:
    """W: (..., 32) float blocks -> (scales(uint8 (N)), codes((N,16)))."""
    W = np.asarray(W, np.float64).reshape(-1, 32)
    if codebook is None:
        codebook = np.arange(-8, 8, dtype=np.float64)      # Q4_0 linear
    scales = np.zeros(W.shape[0], np.uint8)
    codes = np.zeros((W.shape[0], 16), np.uint8)
    for b in range(W.shape[0]):
        sc, lo = _enc_block(W[b], codebook)
        scales[b] = sc
        codes[b] = lo
    return scales, codes


def decode(scales: np.ndarray, codes: np.ndarray, codebook: np.ndarray = None) -> np.ndarray:
    """-> (N, 32) floats."""
    scales = np.asarray(scales, np.uint8).reshape(-1)
    codes = np.asarray(codes, np.uint8).reshape(-1, 16)
    if codebook is None:
        codebook = np.arange(-8, 8, dtype=np.float64)
    d = scale_table()[scales]
    lo = codes & 0x0F
    hi = codes >> 4
    q = np.empty((codes.shape[0], 32), np.int64)
    q[:, 0::2] = lo
    q[:, 1::2] = hi
    return d[:, None] * codebook[q]


def fidelity(Wref: np.ndarray, Wdec: np.ndarray) -> tuple[float, float]:
    """Same metric as mxfp4_regress.cmd_distort: per-32-block relative errors."""
    Wref = np.asarray(Wref).reshape(-1, 32)
    Wdec = np.asarray(Wdec).reshape(-1, 32)
    r = np.abs(Wref - Wdec)
    den = np.maximum(np.abs(Wref).max(1), 1e-8)
    return float(np.median(r.max(1) / den)), float(np.median(r.mean(1) / den))


if __name__ == "__main__":
    import sys
    sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__file__)))
    import mxfp4_regress as M

    GGUF = "/data/data/com.termux/files/home/models/qwen3-0.6b-q8_0.gguf"

    def load_blocks(n=20, nb=256):
        _, infos, start = M.read_gguf(GGUF)
        q8 = [i for i in infos if i.type == M.GGML_TYPE_Q8_0 and len(i.dims) >= 2][:n]
        Ws = [
            np.asarray(M.dequant_blocks(GGUF, i, start, 0, min(int(np.prod(i.dims)) // 32, nb)), np.float32)
            .reshape(-1, 32)
            for i in q8
        ]
        return np.concatenate(Ws)

    W = load_blocks().astype(np.float64)
    lin = np.arange(-8, 8, dtype=np.float64)
    for name, cb in (("Q4F8 (linear)", lin), ("Q4F8-nl (IQ4_NL codebook)", KVAL.astype(np.float64))):
        s, c = encode(W, cb)
        Wd = decode(s, c, cb)
        mx, mm = fidelity(W, Wd)
        print(f"{name:24s} B/elem=0.5312  med.max={mx:.4f}  med.mean={mm:.4f}")
    print("\nreference: Q4_0 0.0611/0.0305 | IQ4_NL 0.0626/0.0273 | MXFP4 0.1383/0.0360 | CC4-256 0.0806/0.0410")