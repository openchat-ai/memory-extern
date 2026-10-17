#!/data/data/com.termux/files/usr/bin/python3
"""bench_q1t_gemm.py — C NEON q1t_gemm (多线程) vs numpy SlimMat."""
import sys, os, ctypes, time, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import SlimMat, read_packslim, PACK_SLIM

lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "q1t_gemm.so"))
def set_arg(lock):
    lib.q1t_gemm_t.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                               ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    lib.q1t_gemm_t.restype = None
    lib.q1t_gemm.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                             ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
    lib.q1t_gemm.restype = None
set_arg(None)

by = read_packslim(PACK_SLIM)[1]
for nm in ["blk.0.attn_q.weight", "blk.0.ffn_gate.weight"]:
    e = by[nm]
    n_in, n_out = e["dims"]
    with open(PACK_SLIM, "rb") as f:
        f.seek(e["offset"]); wf = np.frombuffer(f.read(e["bytes"]), np.uint8).copy()
    x = np.random.default_rng(0).standard_normal((1, n_in), np.float32)
    y = np.zeros((1, n_out), np.float32)
    for nt in (1, 2, 4, 8):
        for _ in range(3): lib.q1t_gemm_t(wf.ctypes.data, n_in, n_out, x.ctypes.data, 1, y.ctypes.data, nt)
        t0 = time.perf_counter()
        for _ in range(30): lib.q1t_gemm_t(wf.ctypes.data, n_in, n_out, x.ctypes.data, 1, y.ctypes.data, nt)
        dt = (time.perf_counter() - t0) / 30
        print(f"{nm.split('.')[2]:9s} {n_in}x{n_out}  thr{nt}: {dt*1e3:.3f} ms")
    # numpy
    sm = SlimMat(PACK_SLIM, e)
    t0 = time.perf_counter(); sm._matmul_np(x); dt = time.perf_counter() - t0
    print(f"           npy: {dt*1e3:.1f} ms")