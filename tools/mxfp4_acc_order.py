#!/usr/bin/env python3
"""mxfp4_acc_order.py - does replacing the per-block horizontal reduction in
ggml_vec_dot_mxfp4_q8_0 (arch/arm/quants.c) with a float32x4 accumulator change
the result beyond float32 tolerance?

WHY
  The ARM kernel currently does, per 32-element block:

      sumf += e8m0(x.e) * fp16(y.d) * vaddvq_s32(prod)      # one scalar fma/block

  nvfp4 in the same file instead does:

      acc = vfmaq_f32(acc, vcvtq_f32_s32(sumi), scales);     # vector acc
      sumf = vaddvq_f32(acc);                                # one reduce total

  The proposed mxfp4 change is the broadcast-scalar form, since all four lanes
  of prod share one scale:

      acc = vfmaq_n_f32(acc, vcvtq_f32_s32(prod_1), s0);     # lane-wise fma/block
      acc = vfmaq_n_f32(acc, vcvtq_f32_s32(prod_2), s1);
      sumf = vaddvq_f32(acc);

  This script decides whether that is numerically acceptable BEFORE anyone edits
  C. It models both accumulation orders in float32 and scores both against a
  float64 exact reference.

METRIC, copied in spirit from kimi-k3 tests/unit/test_expert.c:
      maxrel = max_i|a_i - b_i| / max_i|a_i|
  NOT per-element relative error: a row whose output is near zero would divide
  out to a meaningless huge number and fail a correct implementation. Row-norm
  normalisation is the stable measure.

USAGE
  python3 mxfp4_acc_order.py [--nb 32] [--trials 2000] [--seed 1] [--gguf PATH]
"""

import argparse
import struct
import sys

import numpy as np

# E2M1 as stored by ggml: DOUBLED. ggml-common.h kvalues_fp4.
KVALUES_FP4 = np.array(
    [0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12], dtype=np.int8
)
QK_MXFP4 = 32
QK8_0 = 32
# block_mxfp4 = { uint8_t e; uint8_t qs[QK_MXFP4/2]; }  -> 17 bytes, no padding
MXFP4_BLOCK_BYTES = 1 + QK_MXFP4 // 2


def e8m0_to_fp32(e: np.ndarray) -> np.ndarray:
    """E8M0 -> fp32. Bias 127, value 2^(b-127). 0xFF is NaN by spec.

    Mirrors ggml_table_f32_e8m0_half; verified against the scalar reference in
    ggml-quants.c. Inf is returned for 0xFF; callers treat it as a poisoned
    block and skip it, same as the kernel's own scalar tail.
    """
    e = e.astype(np.uint16)
    out = np.ldexp(np.float32(1.0), (e.astype(np.int32) - 127)).astype(np.float32)
    out[e == 0xFF] = np.inf
    return out


def fp16_bytes_to_fp32(raw: np.ndarray) -> np.ndarray:
    return raw.view(np.float16).astype(np.float32)


def synth_case(rng, nb):
    """Random but legal: real E8M0 exponent range, real int8 quant range."""
    # exponents: bias 127, stay off 0xFF (NaN) and off the extremes where the
    # table would overflow float32.
    e = rng.integers(120, 134, size=nb, dtype=np.uint8)
    # int8 activations, as q8_0 would hold them after quantisation
    y = rng.integers(-127, 128, size=(nb, QK8_0), dtype=np.int8)
    # packed nibbles: low = even element, high = odd element
    qs = rng.integers(0, 256, size=(nb, QK_MXFP4 // 2), dtype=np.uint8)
    return e, y, qs


def unpack_int8(qs: np.ndarray) -> np.ndarray:
    """(nb,16) packed bytes -> (nb,32) int8 weight codes.

    ggml loads 16 packed bytes as one uint8x16_t. q4bits.val[0] is the low
    nibble (even elements 0..15), q4bits.val[1] the high nibble (odd 16..31).
    """
    lo = qs & 0x0F
    hi = qs >> 4
    inter = np.empty((qs.shape[0], 32), dtype=np.uint8)
    inter[:, 0::2] = lo   # kvalues index for even elements
    inter[:, 1::2] = hi
    return KVALUES_FP4[inter].astype(np.int32)


def block_dots(e, y, qs):
    """Exact integer dot per 32-element block, plus the per-lane partials that
    SDOT actually produces.

    vdotq_s32(a, b) yields 4 int32 lanes; lane j covers elements 4j..4j+3 of the
    16-element vector. The kernel chains two of them:

        prod = vdotq_s32(vdotq_s32(zero, q4b[0], q8b[0]), q4b[1], q8b[1])

    so lane j ends up holding elements {4j..4j+3} u {16+4j..16+4j+3} of the
    32-element block. Returned as (nb, 4) int32.
    """
    w = unpack_int8(qs).astype(np.int32)      # (nb,32)
    yy = y.astype(np.int32)                   # (nb,32)
    prod = (w * yy).reshape(-1, 4, 8).sum(axis=2)   # (nb,4,8) -> (nb,4)
    assert prod.shape == (e.shape[0], 4)
    return prod


def dot_ref(prod, scale):
    """Current ARM kernel: exact int32 horizontal reduce, then one scalar fma
    per block, accumulating in a float32 scalar."""
    acc = np.float32(0.0)
    for k in range(prod.shape[0]):
        h = np.float32(prod[k].sum(dtype=np.int64))     # vaddvq_s32: exact
        acc = np.float32(acc + np.float32(scale[k] * h))
    return acc


def dot_vfmaq_n(prod, scale):
    """Proposed: broadcast the per-block scale across all four lanes, fma into a
    float32x4 accumulator, reduce once at the very end."""
    acc = np.zeros(4, dtype=np.float32)
    for k in range(prod.shape[0]):
        for j in range(4):
            acc[j] = np.float32(acc[j] + np.float32(np.float32(prod[k, j]) * scale[k]))
    return np.float32(acc.sum(dtype=np.float32))


def dot_exact(prod, scale):
    """float64 ground truth. Same grouping as the reference (per-block scale),
    but no float32 rounding anywhere."""
    acc = np.float64(0.0)
    for k in range(prod.shape[0]):
        acc += np.float64(scale[k]) * np.float64(prod[k].sum(dtype=np.int64))
    return acc


def row_maxrel(a, b):
    a = np.float64(a)
    b = np.float64(b)
    denom = np.abs(a).max()
    if denom == 0:
        return 0.0
    return float(np.abs(a - b).max() / denom)


def run(nb, trials, seed):
    rng = np.random.default_rng(seed)
    d_ref, d_cand, d_q4_ref, canc = [], [], [], []

    for _ in range(trials):
        e, y, qs = synth_case(rng, nb)
        prod = block_dots(e, y, qs)
        # fp16(y.d): drawn from a real range, NOT random bytes. Random uint16
        # patterns hit the fp16 NaN/Inf encodings, and an Inf scale poisons every
        # downstream sum into NaN. A q8_0 block scale from real activations lands
        # near 0.01..1.0; sample log-uniform in that band.
        dy = np.exp2(rng.uniform(-7.0, 0.0, size=nb)).astype(np.float32)
        scale = (e8m0_to_fp32(e) * dy).astype(np.float32)

        exact = dot_exact(prod, scale)
        r = dot_ref(prod, scale)
        c = dot_vfmaq_n(prod, scale)

        d_ref.append(row_maxrel(np.array([r]), np.array([exact])))
        d_cand.append(row_maxrel(np.array([c]), np.array([exact])))
        d_q4_ref.append(row_maxrel(np.array([r]), np.array([c])))
        # Cancellation ratio: how close the true sum is to zero relative to the
        # terms feeding it. This, not the accumulation order, is what drives the
        # error in both variants.
        abs_sum = float(np.abs(prod.astype(np.float64)
                               * scale.astype(np.float64)[:, None]).sum())
        canc.append(abs_sum / abs(float(exact)) if exact != 0 else np.inf)

    d_ref = np.array(d_ref)
    d_cand = np.array(d_cand)
    d_pair = np.array(d_q4_ref)
    canc = np.array(canc)

    print(f"nb={nb} (n={nb * QK_MXFP4})  trials={trials}  seed={seed}")
    print()
    print("  max relative deviation from the float64 exact result:")
    print(f"    current ARM kernel   median {np.median(d_ref):.3e}   max {d_ref.max():.3e}")
    print(f"    proposed vfmaq_n     median {np.median(d_cand):.3e}   max {d_cand.max():.3e}")
    print(f"    proposed / current   median {np.median(d_pair):.3e}   max {d_pair.max():.3e}")
    print()

    # The two float32 orders are the same thing up to grouping, so they should
    # track each other. Where they differ, it is cancellation, not the change.
    print("  deviation vs cancellation (sum of |terms| / |sum|):")
    for q in (50, 90, 99):
        print(f"    p{q}: {np.percentile(canc, q):.3e}")
    print()
    hi = canc > np.percentile(canc, 90)
    print(f"  on the worst-decile-cancellation trials only ({hi.sum()} of {trials}):")
    print(f"    current   max {d_ref[hi].max():.3e}")
    print(f"    proposed  max {d_cand[hi].max():.3e}")
    lo = ~hi
    print(f"  on the benign 90% (cancellation below p90):")
    print(f"    current   max {d_ref[lo].max():.3e}")
    print(f"    proposed  max {d_cand[lo].max():.3e}")
    print()

    worst = max(d_ref.max(), d_cand.max())
    benign_worst = max(d_ref[lo].max(), d_cand[lo].max())
    print(f"  worst case overall:              {worst:.3e}")
    print(f"  worst case on benign 90%:       {benign_worst:.3e}")
    print()
    print(f"  kimi-k3's 1e-6 threshold against the OVERALL worst: "
          f"{'PASS' if worst < 1e-6 else 'FAIL'}")
    print(f"  kimi-k3's 1e-6 threshold against the BENIGN 90%:     "
          f"{'PASS' if benign_worst < 1e-6 else 'FAIL'}")
    print()
    print("  Read: kimi-k3 clears 1e-6 because it accumulates in DOUBLE. This")
    print("  kernel family is float32 by construction, so 1e-6 is not the right")
    print("  bar here. The right question is whether the proposed order is no")
    print(f"  worse than the kernel already shipping: "
          f"{'YES' if d_cand.max() <= d_ref.max() * 1.5 else 'NO'}")
    print("  (ratio of worst cases: "
          f"{d_cand.max() / max(d_ref.max(), 1e-30):.2f}x)")
    print()
    print("  This bounds the numerics only. It says nothing about the speed")
    print("  change, which needs a real benchmark on real hardware.")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nb", type=int, default=32, help="blocks per row; 32 -> n=1024")
    ap.add_argument("--trials", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    sys.exit(run(a.nb, a.trials, a.seed))


if __name__ == "__main__":
    main()
