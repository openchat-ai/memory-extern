#!/data/data/com.termux/files/usr/bin/python3
"""verify_qxt_gemm.py — 通用 QxT 内核 (b=1..4) vs numpy 参考. C 布局 j*ibp+ib."""
import sys, os, numpy as np, ctypes
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxt_fidelity_scan as Q


def pack_batch(q, b):
    bits = np.empty((q.shape[0], 32 * b), np.uint8)
    for bit in range(b):
        bits[:, np.arange(32) * b + bit] = (q >> bit) & 1
    return np.packbits(bits, axis=1, bitorder="little")


def build(n_in, n_out, b, seed=0):
    rng = np.random.default_rng(seed)
    qk = 32
    nblk = n_in * n_out // qk
    ibp = n_in // qk
    cb = Q.lloyd_cb(np.abs(rng.standard_normal((4000, qk))), b)
    sc = rng.integers(0, 128, (nblk,)).astype(np.uint8)
    q = rng.integers(0, 1 << b, (nblk, qk)).astype(np.int32)
    cod = pack_batch(q, b)
    blk = np.zeros((nblk, 1 + 4 * b), np.uint8)
    blk[:, 0] = sc
    blk[:, 1:] = cod.reshape(nblk, 4 * b)
    raw = np.empty((n_out, ibp, 1 + 4 * b), np.uint8)
    for j in range(n_out):
        for ib in range(ibp):
            raw[j, ib] = blk[j * ibp + ib]
    W = raw.reshape(-1).copy()
    # numpy 参考: 解码 全权重
    stab = Q.scale_table().astype(np.float32)
    wf32 = np.zeros((n_out, n_in), np.float32)
    for j in range(n_out):
        for ib in range(ibp):
            s = stab[sc[j * ibp + ib]]
            codes = q[j * ibp + ib]          # (32,)
            wf32[j, ib * qk:(ib + 1) * qk] = s * cb[codes]
    return W, wf32.T.astype(np.float32), cb, sc


def main():
    lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "q1t_gemm.so"))
    lib.qxt_gemm_t.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                               ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p,
                               ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    lib.qxt_gemm_t.restype = None
    rng = np.random.default_rng(1)
    for b in (2, 3, 4):
        n_in, n_out = 128, 96
        W, Wf32, cb, sc = build(n_in, n_out, b)
        x = rng.standard_normal((1, n_in), np.float32)
        yc = np.zeros((1, n_out), np.float32)
        cbb = np.ascontiguousarray(cb, np.float32)
        lib.qxt_gemm_t(W.ctypes.data, n_in, n_out, x.ctypes.data, 1,
                       yc.ctypes.data, cbb.ctypes.data, b, 2)
        yref = x @ Wf32
        print(f"b={b}: max|C-numpy| = {np.abs(yc[0] - yref[0]).max():.2e}")


if __name__ == "__main__":
    main()