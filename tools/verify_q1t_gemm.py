#!/data/data/com.termux/files/usr/bin/python3
"""verify_q1t_gemm.py — C NEON q1t_gemm vs numpy SlimMat.matmul (same tensor)."""
import sys, os, ctypes, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import SlimMat, read_packslim, PACK_SLIM, QK

lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "q1t_gemm.so"))
lib.q1t_gemm.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                         ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
lib.q1t_gemm.restype = None

meta, by = read_packslim(PACK_SLIM)
name = "blk.0.attn_q.weight"
e = by[name]
n_in, n_out = e["dims"]
print(f"{name} {n_in}x{n_out}  nb={e['bytes']}")

sm = SlimMat(PACK_SLIM, e)
rng = np.random.default_rng(0)
T = 3
x = rng.standard_normal((T, n_in), np.float32)

with open(PACK_SLIM, "rb") as f:
    f.seek(e["offset"])
    wf = np.frombuffer(f.read(e["bytes"]), np.uint8).copy()
y_c = np.zeros((T, n_out), np.float32)
lib.q1t_gemm(wf.ctypes.data, n_in, n_out, x.ctypes.data, T, y_c.ctypes.data)

y_np = sm.matmul(x).astype(np.float32)

d = np.abs(y_np - y_c)
print(f"max|diff| = {d.max():.6f}   rel @scale {np.abs(y_np).max():.4f}")
print("MATCH" if d.max() < 1e-3 else "MISMATCH")