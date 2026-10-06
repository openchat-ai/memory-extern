#!/usr/bin/env python3
"""mxfp4_regress.py - drop-in numerical regression gate for any ggml quant
dot-product kernel, scored against real weights from a real GGUF file.

WHY THIS EXISTS
  The per-block horizontal reduction in ggml_vec_dot_mxfp4_q8_0
  (ggml/src/ggml-cpu/arch/arm/quants.c) looked removable: nvfp4 in the same file
  uses a float32x4 accumulator and reduces once. Rewriting mxfp4 with
  vfmaq_n_f32 measured 4x WORSE in the worst case, because mx/int weights are
  symmetric and the dot product cancels hard, so per-lane rounding does not
  average out. That finding had no permanent home.

  This tool makes any such claim cheap to re-check. Point it at a GGUF, give it
  two or more named implementations, and it reports each one's deviation from a
  float64 ground truth plus the pairwise spread. A new kernel is a new dict
  entry; nothing else changes.

  The absolute bar is NOT kimi-k3's 1e-6. That project accumulates in double
  (src/core/k3_ops.c k3_matmul_mxfp4 uses __m256d), so it has 53 mantissa bits
  to spare. The ggml arm float32 family has 24, and the shipping kernel itself
  already sits around 1e-4 worst case under real cancellation. The meaningful
  gate is REGRESSION against the shipping implementation, not an absolute
  threshold borrowed from a different arithmetic.

  Error metric, following kimi-k3 tests/unit/test_expert.c:
      maxrel = max_i|a_i - b_i| / max_i|a_i|
  Row-norm normalised, never per-element: a row whose output sits near zero
  would divide out to a meaningless huge number and fail a correct kernel.

USAGE
  # list mxfp4 tensors in a GGUF
  python3 mxfp4_regress.py list /path/to/model.gguf

  # run every built-in implementation over a sample of real rows
  python3 mxfp4_regress.py run /path/to/model.gguf --rows 64 --trials 3

  # gate: fail if any implementation regresses past --max-ratio vs the baseline
  python3 mxfp4_regress.py run model.gguf --baseline arm_current --max-ratio 1.5

  # add your own kernel without touching this file
  python3 mxfp4_regress.py run model.gguf --extra my_kernel=/path/to/my_kernel.py

  my_kernel.py must define:
      def dot(elem, lanes, scale) -> float
  where
      elem  : (nb, 32) int64  exact integer products, ggml's PAIR-ORDERED
              pairing (even element 2j x y[j], odd element 2j+1 x y[j+16])
      lanes : (nb, 4)  int32  the SDOT lane sums sdot_lanes(elem) produces
      scale : (nb,)    float32  E8M0(x.e) * fp16(y.d), per 32-element block
  Return the scalar dot product of one row.
"""

import argparse
import importlib.util
import struct
import sys
from collections import namedtuple

import numpy as np

# ---------------------------------------------------------------- ggml tables --

# ggml-common.h kvalues_fp4: E2M1 stored DOUBLED, shared by mxfp4 and nvfp4.
KVALUES_FP4 = np.array(
    [0, 1, 2, 3, 4, 6, 8, 12, 0, -1, -2, -3, -4, -6, -8, -12], dtype=np.int8
)
QK_MXFP4 = 32
GGML_TYPE_MXFP4 = 39
GGML_TYPE_Q4_0 = 2
GGML_TYPE_Q8_0 = 8
GGML_TYPE_I9_0 = 9
GGML_TYPE_IQ4_NL = 20
GGML_TYPE_Q2_K = 10
GGML_TYPE_Q3_K = 11
GGML_TYPE_F32 = 0
GGML_TYPE_COUNT = 43

QK_K = 256
K_EPS = 1e-12

# Bytes per block and block element counts (from ggml-common.h layouts).
BLOCK_BYTES = {
    GGML_TYPE_MXFP4: 1 + QK_MXFP4 // 2,          # {uint8 e; uint8 qs[16]}     17
    GGML_TYPE_Q4_0: 2 + QK_MXFP4 // 2,           # {half d; uint8 qs[16]}      18
    GGML_TYPE_IQ4_NL: 2 + QK_MXFP4 // 2,         # {half d; uint8 qs[16]}      18
    GGML_TYPE_Q8_0: 2 + QK_MXFP4,                # {half d; int8 qs[32]}       34
    GGML_TYPE_Q2_K: 4 + QK_K // 16 + QK_K // 4,  # scales(16) qs(64) d dmin
    GGML_TYPE_Q3_K: QK_K // 4 + QK_K // 8 + 12 + 2,  # qs(64) hmask(32) scales(12) d
}
BLOCK_ELEMS = {
    GGML_TYPE_MXFP4: QK_MXFP4,
    GGML_TYPE_Q4_0: QK_MXFP4,
    GGML_TYPE_IQ4_NL: QK_MXFP4,
    GGML_TYPE_Q8_0: QK_MXFP4,
    GGML_TYPE_Q2_K: QK_K,
    GGML_TYPE_Q3_K: QK_K,
}

# IQ4_NL nonlinear codebook, ggml-common.h kvalues_iq4nl.
KVALUES_IQ4NL = np.array(
    [-127, -104, -83, -65, -49, -35, -22, -10, 1, 13, 25, 38, 53, 69, 89, 113],
    dtype=np.int16,
)

TensorInfo = namedtuple("TensorInfo", "name ndim dims type offset")

# GGUF metadata value type ids
_GGUF_UINT8, _GGUF_INT8 = 0, 1
_GGUF_UINT16, _GGUF_INT16 = 2, 3
_GGUF_UINT32, _GGUF_INT32, _GGUF_FLOAT32 = 4, 5, 6
_GGUF_BOOL = 7
_GGUF_STRING, _GGUF_ARRAY = 8, 9
_GGUF_UINT64, _GGUF_INT64, _GGUF_FLOAT64 = 10, 11, 12


class GGUFError(Exception):
    pass


def _read_gguf_string(f):
    (n,) = struct.unpack("<Q", f.read(8))
    return f.read(n).decode("utf-8", "replace")


def _read_gguf_value(f, vtype):
    if vtype == _GGUF_UINT8:
        return struct.unpack("<B", f.read(1))[0]
    if vtype == _GGUF_INT8:
        return struct.unpack("<b", f.read(1))[0]
    if vtype == _GGUF_UINT16:
        return struct.unpack("<H", f.read(2))[0]
    if vtype == _GGUF_INT16:
        return struct.unpack("<h", f.read(2))[0]
    if vtype == _GGUF_UINT32:
        return struct.unpack("<I", f.read(4))[0]
    if vtype == _GGUF_INT32:
        return struct.unpack("<i", f.read(4))[0]
    if vtype == _GGUF_FLOAT32:
        return struct.unpack("<f", f.read(4))[0]
    if vtype == _GGUF_BOOL:
        return struct.unpack("<B", f.read(1))[0] != 0
    if vtype == _GGUF_STRING:
        return _read_gguf_string(f)
    if vtype == _GGUF_ARRAY:
        (elem,) = struct.unpack("<I", f.read(4))
        (count,) = struct.unpack("<Q", f.read(8))
        if elem in (_GGUF_UINT8, _GGUF_INT8):
            dt = {_GGUF_UINT8: np.uint8, _GGUF_INT8: np.int8}[elem]
            return np.frombuffer(f.read(count), dtype=dt, count=count)
        if elem in (_GGUF_UINT16, _GGUF_INT16):
            sz = 2
            dt = {_GGUF_UINT16: "<u2", _GGUF_INT16: "<i2"}[elem]
            return np.frombuffer(f.read(count * sz), dtype=np.dtype(dt), count=count)
        if elem in (_GGUF_UINT32, _GGUF_INT32, _GGUF_FLOAT32):
            sz = 4
            dt = {_GGUF_UINT32: "<u4", _GGUF_INT32: "<i4", _GGUF_FLOAT32: "<f4"}[elem]
            return np.frombuffer(f.read(count * sz), dtype=np.dtype(dt), count=count)
        if elem in (_GGUF_UINT64, _GGUF_INT64, _GGUF_FLOAT64):
            sz = 8
            dt = {_GGUF_UINT64: "<u8", _GGUF_INT64: "<i8", _GGUF_FLOAT64: "<f8"}[elem]
            return np.frombuffer(f.read(count * sz), dtype=np.dtype(dt), count=count)
        return [_read_gguf_value(f, elem) for _ in range(count)]
    if vtype == _GGUF_UINT64:
        return struct.unpack("<Q", f.read(8))[0]
    if vtype == _GGUF_INT64:
        return struct.unpack("<q", f.read(8))[0]
    if vtype == _GGUF_FLOAT64:
        return struct.unpack("<d", f.read(8))[0]
    raise GGUFError(f"unhandled gguf value type {vtype}")


def read_gguf(path, want_types=None):
    """Minimal reader: enough metadata to locate one tensor's bytes."""
    with open(path, "rb") as f:
        if f.read(4) != b"GGUF":
            raise GGUFError("not a GGUF file")
        version = struct.unpack("<I", f.read(4))[0]
        if version not in (2, 3):
            raise GGUFError(f"gguf version {version} unsupported")

        (n_tensors,) = struct.unpack("<Q", f.read(8))
        (n_kv,) = struct.unpack("<Q", f.read(8))

        kv = {}
        for _ in range(n_kv):
            key = _read_gguf_string(f)
            (vtype,) = struct.unpack("<I", f.read(4))
            kv[key] = _read_gguf_value(f, vtype)

        alignment = int(kv.get("general.alignment", 32))

        infos = []
        for _ in range(n_tensors):
            name = _read_gguf_string(f)
            (ndim,) = struct.unpack("<I", f.read(4))
            dims = struct.unpack(f"<{ndim}Q", f.read(8 * ndim))
            (ttype,) = struct.unpack("<I", f.read(4))
            (off,) = struct.unpack("<Q", f.read(8))
            infos.append(TensorInfo(name, ndim, dims, ttype, off))

        data_start = f.tell()
        data_start += (-data_start) % alignment

    return kv, infos, data_start


def tensor_bytes(path, info, data_start):
    """Read one tensor's raw payload."""
    if info.type not in BLOCK_BYTES:
        raise GGUFError(f"type {info.type} not readable here")
    n_elem = 1
    for d in info.dims:
        n_elem *= d
    nbytes = n_elem // QK_MXFP4 * BLOCK_BYTES[info.type]
    return tensor_slice(path, data_start + info.offset, 0, nbytes)


def tensor_slice(path, abs_off, rel_off, nbytes):
    """Read nbytes from a file at abs_off+rel_off."""
    with open(path, "rb") as f:
        f.seek(abs_off + rel_off)
        return f.read(nbytes)


# ------------------------------------------------------------------- decoding --

def e8m0_to_fp32(e):
    """ggml_table_f32_e8m0_half layout, vectorised (see gguf MXFP4.e8m0_to_fp32_half:
        e < 2 : subnormal   0x00200000 << e
        e >=2 : normal      (e-1) << 23
    0xFF is NaN by spec and stays out of model reach."""
    e = e.astype(np.int32)
    bits = np.where(e < 2, np.uint32(0x00200000) << np.uint32(e),
                    np.uint32(e - 1) << np.uint32(23))
    return bits.view(np.float32)


def decode_mxfp4(raw, n_elem):
    """Packed mxfp4 -> (codes int8 (n,32), e8m0 uint8 (n,)).

    block_mxfp4 is { uint8_t e; uint8_t qs[QK_MXFP4/2]; } with no padding, 17
    bytes per 32 weights. Reference element order: low nibble = elements 0..15,
    high nibble = elements 16..31.
    """
    blk_bytes = 1 + QK_MXFP4 // 2
    nb = n_elem // QK_MXFP4
    buf = np.frombuffer(raw, dtype=np.uint8, count=nb * blk_bytes)
    buf = buf.reshape(nb, blk_bytes)
    e = buf[:, 0].copy()
    qs = buf[:, 1:]

    inter = np.empty((nb, QK_MXFP4), dtype=np.uint8)
    inter[:, 0:16] = qs & 0x0F
    inter[:, 16:32] = qs >> 4
    return KVALUES_FP4[inter].astype(np.int32), e


def dequant_blocks(path, info, data_start, b0, nb_le):
    """Dequantise blocks [b0, b0+nb_le) of a quantised tensor, byte-sliced.

    Returns (nb_le, QK) float64 in element order (even element 2j = low nibble
    of byte j, odd = high nibble). Never materialises the whole tensor.
    QK is 32 for the nibble types, 256 for the K-quant superblocks.
    """
    ggml_type = info.type
    bb = BLOCK_BYTES[ggml_type]
    qk = BLOCK_ELEMS[ggml_type]
    n_elem = int(np.prod(info.dims))
    nb_total = n_elem // qk
    b0 = min(b0, nb_total)
    nb_le = min(nb_le, nb_total - b0)
    raw = tensor_slice(path, data_start + info.offset, b0 * bb, nb_le * bb)
    buf = np.frombuffer(raw, dtype=np.uint8, count=nb_le * bb).reshape(nb_le, bb)

    if ggml_type == GGML_TYPE_MXFP4:
        codes = decode_mxfp4_slice(buf)
        return codes.astype(np.float64) * e8m0_to_fp32(buf[:, 0])[:, None]
    if ggml_type == GGML_TYPE_Q2_K:
        return dequant_q2_K(buf)
    if ggml_type == GGML_TYPE_Q3_K:
        return dequant_q3_K(buf)

    d = buf[:, 0:2].view(np.float16).astype(np.float64).reshape(-1, 1)
    qs = buf[:, 2:]

    if ggml_type == GGML_TYPE_Q8_0:
        return qs.astype(np.int8).astype(np.float64) * d

    # nibble-packed: 16 bytes -> 32 elements, LOW nibble = elements 0..15,
    # HIGH nibble = elements 16..31 (ggml dequantize_row_* reference order).
    q4 = np.empty((nb_le, QK_MXFP4), dtype=np.int32)
    q4[:, 0:16] = (qs & 0x0F).astype(np.int32)
    q4[:, 16:32] = (qs >> 4).astype(np.int32)

    if ggml_type == GGML_TYPE_Q4_0:
        return (q4 - 8).astype(np.float64) * d
    if ggml_type == GGML_TYPE_IQ4_NL:
        return KVALUES_IQ4NL[q4].astype(np.float64) * d

    raise GGUFError(f"no decoder for type {ggml_type}")


def dequant_q2_K(buf):
    """buf: (n, 84) q2_K blocks -> (n, 256) float64, faithful port of
    ggml-quants.c dequantize_row_q2_K.

    Memory layout (struct order): scales[16], qs[64], d(fp16), dmin(fp16).
    Loop structure: for n in (0,128): shift {0,2,4,6} x j{0..3}, each scale
    pair (dl from low nibble, ml from high nibble) covers 16 elements of the
    two split groups inside 32 q bytes.
    """
    n = buf.shape[0]
    d = buf[:, 80:82].view(np.float16).astype(np.float64).reshape(-1, 1)
    dmin = buf[:, 82:84].view(np.float16).astype(np.float64).reshape(-1, 1)
    scales = buf[:, 0:16]
    qs = buf[:, 16:80]
    out = np.empty((n, QK_K), dtype=np.float64)
    for half in (0, 1):
        for j in range(4):
            shift = 2 * j
            for t in (0, 1):
                sc = scales[:, 8 * half + 2 * j + t]
                scs = sc.astype(np.float64)
                dl = (d.reshape(-1) * (sc & 15).astype(np.float64))
                ml = (dmin.reshape(-1) * (sc >> 4).astype(np.float64))
                for l in range(16):
                    code = ((qs[:, 32 * half + l + 16 * t] >> shift) & 3)
                    out[:, 128 * half + 32 * j + 16 * t + l] = (
                        dl * code.astype(np.float64) - ml
                    )
    return out


def dequant_q3_K(buf):
    """buf: (n, 110) q3_K blocks -> (n, 256) float64, faithful port of
    ggml-quants.c dequantize_row_q3_K.

    Memory layout (struct order): hmask[32], qs[64], scales[12], d(fp16),
    total 110 bytes. The 16 block scales are 6-bit codes c (0..63) packed as:
      c = lo4 | (hi2 << 4),  lo4 in scales[j%8] nibble (j/8), hi2 in
      scales[8 + j%4] bits 2*(j/4); real scale = d * (c - 32).
    High-bit: hmask byte l+16*t, bit m = j + 4*half.
    """
    n = buf.shape[0]
    d_all = buf[:, 108:110].view(np.float16).astype(np.float64).reshape(-1, 1)
    hmask = buf[:, 0:32]
    qs = buf[:, 32:96]
    raw = buf[:, 96:108]

    c = np.empty((n, 16), dtype=np.int64)
    for j in range(16):
        lo4 = (raw[:, j % 8] >> (4 * (j // 8))) & 0xF
        hi2 = (raw[:, 8 + j % 4] >> (2 * (j // 4))) & 3
        c[:, j] = lo4 | (hi2 << 4)

    out = np.empty((n, QK_K), dtype=np.float64)
    for half in (0, 1):
        for j in range(4):
            shift = 2 * j
            mbit = j + 4 * half
            for t in (0, 1):
                dl = d_all * (c[:, 8 * half + 2 * j + t] - 32)[:, None]
                for l in range(16):
                    code = ((qs[:, 32 * half + l + 16 * t] >> shift) & 3)
                    hm = (hmask[:, l + 16 * t] >> mbit) & 1
                    qq = code.astype(np.float64) - np.where(hm, 0.0, 4.0)
                    out[:, 128 * half + 32 * j + 16 * t + l] = dl[:, 0] * qq
    return out


def decode_mxfp4_slice(buf):
    """buf: (nb, 17) mxfp4 block bytes -> E2M1 codes (nb, 32) int32.

    Low nibble = elements 0..15, high nibble = elements 16..31 (matches the
    reference dequantize_row_* layout, not SIMD even/odd pairing).
    """
    qs = buf[:, 1:]
    inter = np.empty((qs.shape[0], QK_MXFP4), dtype=np.uint8)
    inter[:, 0:16] = qs & 0x0F
    inter[:, 16:32] = qs >> 4
    return KVALUES_FP4[inter].astype(np.int32)


def pair_products(codes, yq):
    """The genuine int32 products, in element order, with ggml's PAIRING.

    Scalar reference (quants.c ggml_vec_dot_mxfp4_q8_0), per 32-element block:
        sumi1 += y[ib].qs[j]          * kvalues[x[ib].qs[j] & 0xf]    # j = 0..15
        sumi2 += y[ib].qs[j + QK/2]   * kvalues[x[ib].qs[j] >> 4]     # j = 0..15
    Element 2j (byte j low nibble, code stored in codes[:, 2j]) is paired with
    activation y[j]; element 2j+1 (byte j high nibble, codes[:, 2j+1]) with
    y[j+16]. NOT element-wise. Returns (nb, 32) int64 in element order.
    """
    even = codes[:, 0::2].astype(np.int64)   # element 2j
    odd  = codes[:, 1::2].astype(np.int64)   # element 2j+1
    y00  = yq.astype(np.int64)[:, 0:16]
    y16  = yq.astype(np.int64)[:, 16:32]
    out = np.empty_like(codes, dtype=np.int64)
    out[:, 0::2] = even * y00
    out[:, 1::2] = odd * y16
    return out


def sdot_lanes(elem):
    """Group the pair-aligned products into the 4 lanes SDOT produces.

    After pair_products, element 8j..8j+7 of a block contains even pair 4j..4j+3
    (columns 8j,8j+2,..) and odd pair 4j..4j+3 (columns 8j+1,8j+3,..), which is
    exactly what NEON lane j accumulates in its chained sdot. So the lane is the
    sum of eight consecutive elements.
    """
    return elem.reshape(-1, 4, 8).sum(axis=2).astype(np.int32)


# -------------------------------------------------------------- implementations --

def arm_current(elem, lanes, scale):
    """Verbatim port of ggml_vec_dot_mxfp4_q8_0's NEON nrc==1 loop.

        sumf += e8m0(x.e)*fp16(y.d)*vaddvq_s32(prod)

    Exact int32 horizontal reduce per block, then one scalar fma per block into
    a float32 scalar. This is the baseline every regression is measured against.
    """
    acc = np.float32(0.0)
    for k in range(lanes.shape[0]):
        h = np.float32(int(lanes[k].sum(dtype=np.int64)))
        acc = np.float32(acc + np.float32(scale[k] * h))
    return float(acc)


def vfmaq_n(elem, lanes, scale):
    """The rejected rewrite: broadcast the per-block scale across all four lanes,
    fma into a float32x4 accumulator, reduce once at the end.

    Mathematically equivalent to arm_current by distributivity. Numerically
    worse: mx/int codes are symmetric, the dot product cancels hard, and the
    per-lane rounding does not average out.
    """
    acc = np.zeros(4, dtype=np.float32)
    for k in range(lanes.shape[0]):
        for j in range(4):
            acc[j] = np.float32(acc[j] + np.float32(np.float32(lanes[k, j]) * scale[k]))
    return float(np.float32(acc.sum(dtype=np.float32)))


def float64_exact(elem, lanes, scale):
    """Ground truth: same block grouping as arm_current, no float32 rounding."""
    acc = np.float64(0.0)
    for k in range(lanes.shape[0]):
        acc += np.float64(scale[k]) * np.float64(lanes[k].sum(dtype=np.int64))
    return float(acc)


def naive_dequant(elem, lanes, scale):
    """Independent second path: scale every ELEMENT, then one flat float64 sum.

    This mirrors kimi-k3's k3_mxfp4_dequant + k3_matmul pair and is what makes
    the comparison a real cross-check rather than one implementation against
    itself. It ignores the SDOT lane grouping entirely, so it shares nothing
    with arm_current but the same exact products.
    """
    w = elem.astype(np.float64) * scale.astype(np.float64)[:, None]
    return float(w.sum(dtype=np.float64))


BUILTINS = {
    "arm_current": arm_current,
    "vfmaq_n": vfmaq_n,
    "naive_dequant": naive_dequant,
    "float64_exact": float64_exact,
}
BASELINE = "arm_current"


# ------------------------------------------------------------------- reporting --

def row_maxrel(a, b):
    a, b = np.float64(a), np.float64(b)
    denom = np.abs(a).max()
    if denom == 0:
        return 0.0
    return float(np.abs(a - b).max() / denom)


def synthetic_activation(n_elem, rng, kind):
    """Activations, matched to what q8_0 quantisation actually produces.

    k3_mxfp4_dequant, ggml's q8_0 quantiser and llama.cpp all clamp to int8
    range; real activation blocks carry a per-block fp16 scale near 0.01..1.0.
    NaN/Inf fp16 encodings are unreachable here because the scale is generated
    log-uniform, never by masking random uint16 bits.
    """
    if kind == "gaussian":
        x = rng.standard_normal(n_elem) * 0.5
    elif kind == "uniform":
        x = rng.uniform(-1.0, 1.0, n_elem)
    elif kind == "outlier":
        x = rng.standard_normal(n_elem) * 0.05
        x[rng.integers(0, n_elem, max(1, n_elem // 64))] *= 40.0
    else:
        raise ValueError(kind)
    x = np.clip(x, -1.0, 1.0)

    nb = n_elem // QK_MXFP4
    per = x.reshape(nb, QK_MXFP4)
    amax = np.abs(per).max(axis=1) + 1e-12
    q = np.rint(per / (amax / 127.0)[:, None]).clip(-127, 127).astype(np.int8)
    d = (amax / 127.0).astype(np.float32)
    return q.astype(np.int32), d


def load_extra(spec):
    name, _, path = spec.partition("=")
    if not path:
        raise SystemExit(f"--extra needs NAME=PATH, got {spec!r}")
    modname = path.replace("/", "_").replace(".", "_")
    s = importlib.util.spec_from_file_location(modname, path)
    if s is None or s.loader is None:
        raise SystemExit(f"cannot load {path!r}")
    mod = importlib.util.module_from_spec(s)
    s.loader.exec_module(mod)
    if not hasattr(mod, "dot"):
        raise SystemExit(f"{path} does not define dot(elem, lanes, scale)")
    return name, mod.dot


def cmd_distort(ref_gguf, cand_gguf, rows, seed, label, blocks_per_tensor=512):
    """Dequant real blocks from a reference GGUF and a candidate GGUF, compare
    per-block against the reference, report distortion per format.

    The reference is expected to be the q8_0 source (the candidate models here
    were re-quantised from it), so this measures PURE STORAGE FIDELITY: how much
    each 4-bit layout loses relative to the same underlying values. Speed is not
    in this tool; combine with a real benchmark (e.g. the earlier latin-square
    run) for the complete answer.

    Memory-bounded: reads blocks_per_tensor blocks per tensor, never the whole
    tensor. Distortion metric is the one the NEON kernels actually experience:
    per-32-block max abs error / block max abs (relative, per block).
    """
    _, ref_infos, ref_start = read_gguf(ref_gguf)
    _, cand_infos, cand_start = read_gguf(cand_gguf)
    rd = {i.name: i for i in ref_infos}
    cd = {i.name: i for i in cand_infos}

    names = sorted(set(rd) & set(cd))
    if rows:
        names = names[: rows]

    cand_types = (GGML_TYPE_MXFP4, GGML_TYPE_Q4_0, GGML_TYPE_IQ4_NL,
                  GGML_TYPE_Q2_K, GGML_TYPE_Q3_K)
    pairs = [
        (n, rd[n], cd[n]) for n in names
        if rd[n].type == GGML_TYPE_Q8_0
        and cd[n].type in cand_types
        and rd[n].dims == cd[n].dims
    ]
    # skip embeddings / output heads: convoluted shapes, not kernel blocks
    pairs = [p for p in pairs if len(p[1].dims) >= 2]

    if not pairs:
        raise SystemExit("no q8_-vs-4bit 2-D tensor pairs to compare")

    rng = np.random.default_rng(seed)
    rel = []
    rel_mean = []
    nt = 0
    for _, r, c in pairs:
        nb = int(np.prod(r.dims)) // QK_MXFP4   # reference grain is 32
        n_b = min(blocks_per_tensor, nb)
        b0 = int(rng.integers(max(1, nb - n_b + 1)))
        # reference: n_b blocks of 32 elements
        Wref = dequant_blocks(ref_gguf, r, ref_start, b0, n_b)
        # candidate covers the SAME element window [b0*32, (b0+n_b)*32)
        qk_cand = BLOCK_ELEMS.get(c.type, QK_MXFP4)
        c0_e = b0 * QK_MXFP4
        end_e = c0_e + n_b * QK_MXFP4
        sb = c0_e // qk_cand
        eb = (end_e + qk_cand - 1) // qk_cand
        Wcand_flat = dequant_blocks(cand_gguf, c, cand_start,
                                    sb, eb - sb).reshape(-1)
        Wcand = Wcand_flat[c0_e % qk_cand: c0_e % qk_cand + n_b * QK_MXFP4]
        Wcand = Wcand.reshape(n_b, QK_MXFP4)
        denom = np.abs(Wref).max(axis=1)
        diff = np.abs(Wref - Wcand)
        rel.append(diff.max(axis=1) / np.maximum(denom, K_EPS))
        rel_mean.append(diff.mean(axis=1) / np.maximum(denom, K_EPS))
        nt += 1

    if not nt:
        raise SystemExit("no valid pair sampled")

    arr = np.concatenate(rel)
    arr_mean = np.concatenate(rel_mean)
    print(f"{label or cand_gguf}")
    print(f"  sampled {nt} tensors x {blocks_per_tensor} blocks vs {ref_gguf}")
    print(f"  per-block MAX-abs / block-max-abs: "
          f"median {np.median(arr):.4e}  p99 {np.percentile(arr, 99):.4e}  "
          f"max {arr.max():.4e}")
    print(f"  per-block MEAN-abs / block-max-abs: "
          f"median {np.median(arr_mean):.4e}  p99 {np.percentile(arr_mean, 99):.4e}  "
          f"max {arr_mean.max():.4e}")
    return 0


def cmd_list(path):
    _, infos, _ = read_gguf(path)
    sel = [i for i in infos if i.type == GGML_TYPE_MXFP4]
    if not sel:
        print("no MXFP4 tensors in this file")
        return 0
    total = sum(int(np.prod(i.dims)) for i in sel)
    print(f"{len(sel)} MXFP4 tensors, {total:,} elements\n")
    for i in sel[:20]:
        print(f"  {i.name:44s} {str(list(i.dims)):18s} {int(np.prod(i.dims)):,} elem")
    if len(sel) > 20:
        print(f"  ... and {len(sel) - 20} more")
    return 0


def cmd_run(path, rows, trials, act, seed, impls, baseline, max_ratio):
    _, infos, data_start = read_gguf(path)
    sel = [i for i in infos if i.type == GGML_TYPE_MXFP4]
    if not sel:
        raise SystemExit("no MXFP4 tensors; nothing to regress")

    rng = np.random.default_rng(seed)
    results = {k: [] for k in impls}
    cancellation = []
    skipped = 0

    for ti, info in enumerate(sel):
        if rows and ti >= rows:
            break
        n_elem = int(np.prod(info.dims))
        if n_elem % QK_MXFP4:
            skipped += 1
            continue
        try:
            raw = tensor_bytes(path, info, data_start)
        except GGUFError:
            skipped += 1
            continue

        codes, e = decode_mxfp4(raw, n_elem)
        e8 = e8m0_to_fp32(e)
        if not np.all(np.isfinite(e8)):
            skipped += 1
            continue

        for _ in range(trials):
            yq, dy = synthetic_activation(n_elem, rng, act)
            elem = pair_products(codes, yq)
            lanes = sdot_lanes(elem)
            scale = (e8 * dy).astype(np.float32)

            vals = {}
            for name, fn in impls.items():
                vals[name] = np.float64(fn(elem, lanes, scale))

            exact = vals["float64_exact"]
            for name in impls:
                results[name].append(row_maxrel(np.array([vals[name]]),
                                              np.array([exact])))

            terms = np.abs(yq.astype(np.float64) * scale.astype(np.float64)[:, None])
            cancellation.append(float(terms.sum()) / max(abs(exact), 1e-300))

    if skipped:
        print(f"  skipped {skipped} tensor(s) (odd size or E8M0 NaN scale)\n")

    n = len(results[BASELINE])
    if n == 0:
        raise SystemExit("no usable rows")
    cancellation = np.array(cancellation)

    print(f"{path}")
    print(f"{n} rows scored, activation={act}, seed={seed}")
    print(f"mx/int codes are symmetric, so the dot product cancels: "
          f"sum|terms|/|sum| p50={np.percentile(cancellation, 50):.1f} "
          f"p99={np.percentile(cancellation, 99):.1f}\n")
    print(f"  {'implementation':22s} {'median':>11s} {'p99':>11s} {'max':>11s} "
          f"{'vs baseline max':>17s}")
    base_max = max(results[baseline])
    for name in impls:
        r = np.array(results[name])
        ratio = r.max() / base_max if base_max else float("nan")
        flag = ""
        if name != baseline and max_ratio and ratio > max_ratio:
            flag = f"  REGRESS {ratio:.2f}x > {max_ratio}"
        print(f"  {name:22s} {np.median(r):11.3e} {np.percentile(r, 99):11.3e} "
              f"{r.max():11.3e} {ratio:16.2f}x{flag}")
    print()

    failed = False
    if max_ratio:
        for name in impls:
            if name == baseline:
                continue
            ratio = np.array(results[name]).max() / base_max if base_max else 0
            if ratio > max_ratio:
                failed = True
        print(f"gate: max ratio {max_ratio} against {baseline} -> "
              f"{'FAIL' if failed else 'PASS'}")
    else:
        print("gate: not applied (pass --max-ratio to enable)")
    print("this measures numerics only; speed needs a real benchmark")
    return 1 if failed else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("list", help="list MXFP4 tensors")
    p.add_argument("gguf")

    p = sub.add_parser("distort",
                       help="storage fidelity: dequant real tensors vs a q8_0 "
                            "reference GGUF")
    p.add_argument("ref", help="reference (q8_0) GGUF")
    p.add_argument("cand", help="candidate (4-bit) GGUF")
    p.add_argument("--rows", type=int, default=0, help="tensors to sample; 0=all")
    p.add_argument("--label", default=None)
    p.add_argument("--seed", type=int, default=1)

    p = sub.add_parser("run", help="score implementations against float64")
    p.add_argument("gguf")
    p.add_argument("--rows", type=int, default=64,
                   help="tensors to sample; 0 = all")
    p.add_argument("--trials", type=int, default=3,
                   help="activation draws per tensor")
    p.add_argument("--act", default="gaussian",
                   choices=["gaussian", "uniform", "outlier"])
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--baseline", default=BASELINE)
    p.add_argument("--max-ratio", type=float, default=None,
                   help="fail if any impl's max error exceeds baseline x this")
    p.add_argument("--extra", action="append", default=[],
                   help="NAME=/path/to/kernel.py with dot(blocks, scales, dy)")
    p.add_argument("--impl", action="append", default=[],
                   help="restrict to a builtin; repeatable")

    a = ap.parse_args()
    if a.cmd == "list":
        return cmd_list(a.gguf)
    if a.cmd == "distort":
        return cmd_distort(a.ref, a.cand, a.rows, a.seed, a.label)

    impls = dict(BUILTINS)
    if a.impl:
        missing = [k for k in a.impl if k not in impls]
        if missing:
            raise SystemExit(f"unknown builtin(s): {', '.join(missing)}")
        impls = {k: impls[k] for k in a.impl}
    if "float64_exact" not in impls:
        impls["float64_exact"] = float64_exact
    for spec in a.extra:
        name, fn = load_extra(spec)
        impls[name] = fn

    if a.baseline not in impls:
        raise SystemExit(f"baseline {a.baseline!r} is not among the implementations")

    return cmd_run(a.gguf, a.rows, a.trials, a.act, a.seed, impls,
                   a.baseline, a.max_ratio)


if __name__ == "__main__":
    sys.exit(main())
