#!/usr/bin/env python3
"""Visual-mechanism storage formats for real transformer weights.

Two concrete codings inspired by how the eye/brain compresses the visual field:

EYE   - spatial change coder (center-surround): each 32-block carries a local
        anchor (mean) + local scale; only the signed deviation from the anchor
        is coded.  Simulates "store changes, not absolute values".
FOVEA - value-domain foveation: per-32 anchor/scale like EYE, but element codes
        read from a NONUNIFORM 16-level codebook fitted (quantile) to the real
        residual distribution -- sensitivity concentrates where values are
        dense (fovea), coarser in the tails (periphery).

Both keep fixed 32-element alignment (i8mm/SDOT-compatible), decode to float
with arithmetic (EYE) / small LUT (FOVEA), no variable-length codes, so block
random access is O(1).  Fidelity is measured with the same relative-error
metric as the existing five-format curve in mxfp4_regress.
"""
import os
import sys
import argparse
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M  # noqa: E402

GGUF = "/data/data/com.termux/files/home/models/qwen3-0.6b-q8_0.gguf"
BS = 32
K_EPS = 1e-12


def load_blocks(n_tensors=20, n_blk=256):
    _, infos, start = M.read_gguf(GGUF)
    q8 = [i for i in infos if i.type == M.GGML_TYPE_Q8_0 and len(i.dims) >= 2][:n_tensors]
    Ws = []
    for info in q8:
        nb = int(np.prod(info.dims)) // BS
        W = M.dequant_blocks(GGUF, info, start, 0, min(nb, n_blk))
        Ws.append(np.asarray(W, dtype=np.float32).reshape(-1, BS))
    return np.concatenate(Ws)


# ---------------------------------------------------------------- EYE codec
def eye_encode(W, bits=4):
    """W: (N,BS) float32. Returns packed (anchor, step, codes).

    Center-surround: 'surround' = block mean, 'step' = max_abs / 2^(bits-1) so
    the signed grid exactly covers +/-max (Q4_0-style calibration, no saturate).
    """
    mu = W.mean(1, keepdims=True).astype(np.float16).astype(np.float32)
    lo = 1 << (bits - 1)                       # -lo .. lo-1
    step = np.abs(W).max(1, keepdims=True) / lo
    step = np.where(step < 1e-30, 1.0, step).astype(np.float32)
    code = np.clip(np.rint((W - mu) / (step + 1e-15)), -lo, lo - 1).astype(np.int8)
    return mu, step, code, bits


def eye_decode(mu, step, code):
    return mu + code * step


# -------------------------------------------------------------- FOVEA codec
def fit_levels(Wtrain, R=16, bits=4):
    """Quantile-fitted signed codebook covering +/-max (per block d units).

    Foveation: probability-shaped (quantile) spacing - dense in the body of the
    distribution, coarse in the tails, endpoints pinned at +/-max so nothing
    saturates.  levels are in units of per-block step d = max/2^(bits-1).
    """
    rng = np.random.default_rng(0)
    sel = Wtrain[rng.integers(0, Wtrain.shape[0], min(4000, Wtrain.shape[0]))]
    m = sel.mean(1, keepdims=True).astype(np.float16).astype(np.float32)
    lo = 1 << (bits - 1)
    d = np.abs(sel).max(1, keepdims=True) / lo
    d = np.where(d < 1e-30, 1.0, d).astype(np.float32)
    r = ((sel - m) / (d + 1e-15)).ravel()      # in d-code units, spans ~[-lo, lo]
    r = np.clip(r, -lo + 1e-3, lo - 1e-3)
    qs = np.linspace(1.0 / R, 1.0, R)
    lv = np.quantile(r, qs).astype(np.float32)  # asymmetric: R levels across range
    return lv


def fovea_encode(W, levels):
    mu = W.mean(1, keepdims=True).astype(np.float16).astype(np.float32)
    lo = 1 << (levels.size - 1)
    d = np.abs(W).max(1, keepdims=True) / lo
    d = np.where(d < 1e-30, 1.0, d).astype(np.float32)
    r = (W - mu) / (d + 1e-15)
    idx = (np.abs(r[:, :, None] - levels[None, None, :])).argmin(2)
    return mu, d, idx, levels


def fovea_decode(mu, d, idx, levels):
    return mu + levels[idx] * d


# ------------------------------------------------------------------ measure
def fidelity(Wref, Wdec):
    """Same metric as mxfp4_regress.cmd_distort: per-32-block max/mean abs err
    divided by block-max-abs of the reference.  medians over blocks."""
    r = np.abs(Wref - Wdec)                          # (N, 32)
    denom = np.maximum(np.abs(Wref).max(1), K_EPS)   # block peak (N,)
    bmax = r.max(1) / denom
    bmean = r.mean(1) / denom
    return float(np.median(bmax)), float(np.median(bmean))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tensors", type=int, default=20)
    ap.add_argument("--blocks", type=int, default=256)
    args = ap.parse_args()

    W = load_blocks(args.tensors, args.blocks)
    Wref = W.astype(np.float32)
    nblk = Wref.shape[0]

    # train codebook on a disjoint head slice, evaluate on the rest
    cut = max(1, int(nblk * 0.2))
    train, test = Wref[:cut], Wref[cut:]

    print(f"blocks: {nblk}  ({args.tensors} tensors x {args.blocks}/tensor), train {cut}, test {test.shape[0]}")

    # EYE at 4.5 bits (like Q4_0) and true at bits: 16/32 + bits
    mu, st, code, bits = eye_encode(test, bits=4)
    Deye = eye_decode(mu, st, code)
    bme, bme_ = fidelity(test, Deye)
    print(f"EYE   4b + fp16 anchor/step ({32 / 32 + 4:.2f} b/elem, no mu tax): "
          f"med.max={bme:.4f}  med.mean={bme_:.4f}")

    # EYE 5-bit (name it retina-5)
    mu5, st5, c5, _ = eye_encode(test, bits=5)
    D5 = eye_decode(mu5, st5, c5)
    m5, m5m = fidelity(test, D5)
    print(f"EYE   5b codes + fp16 anchor/step ({32 / 32 + 5:.2f} b/elem): "
          f"med.max={m5:.4f}  med.mean={m5m:.4f}")

    # FOVEA 4-bit fitted nonuniform
    lv = fit_levels(train)
    muF, stF, idx, lv = fovea_encode(test, lv)
    Df = fovea_decode(muF, stF, idx, lv)
    bf, bfm = fidelity(test, Df)
    print(f"FOVEA 4b fitted-nonuniform + fp16 step ({32 / 32 + 4:.2f} b/elem): "
          f"med.max={bf:.4f}  med.mean={bfm:.4f}")
    print(f"      fitted levels (std units): {np.array2string(lv, precision=3)}")


def cli_cc4():
    """Clustered-columnstore 4-bit: 256-elem superblock, per-grain fp16 scales
    stored in a scale column + 4-bit code column (database projection-index
    semantics).  Compare byte size + fidelity vs the five-format curve."""
    import contextlib
    with contextlib.redirect_stdout(open(os.devnull, "w")):
        pass
    SB, K = 256, 1e-12
    W = load_blocks(20, 256).astype(np.float32)
    test = W[1024:].ravel()
    n = test.size // SB
    test = test[: n * SB].reshape(n, SB)

    def quant(grain):
        ns = SB // grain
        tg = test.reshape(n, ns, grain)
        j = np.argmax(np.abs(tg), axis=-1)
        maxv = np.take_along_axis(tg, j[..., None], -1)[..., 0]
        d = maxv / -8.0
        d = np.where(np.abs(d) < 1e-30, 1.0, d)
        id_ = np.where(np.abs(d) > 1e-30, 1.0 / d, 0.0)
        xi = np.clip((tg * id_[..., None] + 8.5).astype(np.int32), 0, 15).astype(np.uint8)
        return (d, xi)

    rows = []
    for name, grain in (("CC4-32s", 32), ("CC4-64", 64), ("CC4-128", 128), ("CC4-256", 256)):
        d, xi = quant(grain)
        ns = SB // grain
        dec = ((xi.astype(np.int32) - 8) * d[..., None].astype(np.float32)).reshape(n, SB)
        r = np.abs(test - dec)
        den = np.maximum(np.abs(test).max(1), K)
        mx, mm = np.median(r.max(1) / den), np.median(r.mean(1) / den)
        Belem = (grain // 2 * ns + 2 * ns) / SB
        rows.append((name, Belem, mx, mm))

    print("clustered columnstore 4-bit (ggml Q4_0-correct encoder)")
    print(f"{'fmt':9s} {'B/elem':7s} {'med.max':8s} {'med.mean':9s}")
    for name, b, mx, mm in rows:
        print(f"{name:9s} {b:6.3f} {mx:8.4f} {mm:9.4f}")
    print("Q4_0  0.562   0.0611   0.0303  (measured llama.cpp Q4_0)")
    print("IQ4_NL 0.562  0.0622   0.0272")
    print("Q2_K  0.328   0.2080   0.0830")

    print("\nreference five-format curve (same metric):")
    for nm, (m, mm) in {"Q4_0  4.5b": (0.0611, 0.0305), "IQ4_NL 4.5b": (0.0622, 0.0272),
                        "Q3_K_S 3.4b": (0.119, 0.053),  "MXFP4 4.5b": (0.141, 0.036),
                        "Q2_K  2.6b": (0.208, 0.083)}.items():
        print(f"  {nm}: med.max={m:.4f}  med.mean={mm:.4f}")


if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "cc4":
        cli_cc4()
    else:
        main()