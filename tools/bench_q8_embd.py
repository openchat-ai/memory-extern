#!/data/data/com.termux/files/usr/bin/python3
"""bench_q8_embd.py — Q8_0 NEON 末投影 vs numpy fp32 embd."""
import sys, os, ctypes, time, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import q1t_stream as S

lib = ctypes.CDLL(os.path.join(os.path.dirname(os.path.abspath(__file__)), "q1t_gemm.so"))
lib.q8_gemm_proj.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                             ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
lib.q8_gemm_proj.restype = None

eng = S.StreamEngine()
t = [x for x in eng.infos if x.name == "token_embd.weight"][0]
n_in, n_out = t.dims
with open(S.SRC, "rb") as f:
    f.seek(eng.ds + t.offset)
    raw = np.frombuffer(f.read(n_out * (n_in // 32) * 34), np.uint8).copy()

rng = np.random.default_rng(0)
x = rng.standard_normal((1, n_in), np.float32)

sub = 256
ref = x @ eng.embd[:, :sub]
yc = np.empty(sub, np.float32)
lib.q8_gemm_proj(raw.ctypes.data, n_in, sub, x.ctypes.data, 1, yc.ctypes.data, 2)
print(f"sub(256col) q8kernel vs fp32: max|diff|={np.abs(yc - ref[0]).max():.2e}")

y = np.empty(n_out, np.float32)
lib.q8_gemm_proj(raw.ctypes.data, n_in, n_out, x.ctypes.data, 1, y.ctypes.data, 2)
t0 = time.perf_counter(); y = np.empty_like(y); lib.q8_gemm_proj(raw.ctypes.data, n_in, n_out, x.ctypes.data, 1, y.ctypes.data, 2)
dt = time.perf_counter() - t0
t0 = time.perf_counter(); x @ eng.embd; dtn = time.perf_counter() - t0
print(f"q8 kernel(2th): {dt*1e3:.1f} ms   numpy fp32: {dtn*1e3:.1f} ms   speedup {dtn/dt:.1f}x")