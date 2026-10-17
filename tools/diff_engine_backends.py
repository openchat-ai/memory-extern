#!/data/data/com.termux/files/usr/bin/python3
"""diff_engine_backends.py — C-kernel engine vs numpy engine: identical greedy tokens?"""
import sys, os, time, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import q1t_stream as S


def greedy(eng, use_c, n_new=8):
    for m in eng.mat.values():
        m.use_c = use_c
    ids = list(eng.encode("1+1=?"))
    t0 = time.time()
    lg, cache = eng.forward(np.array(ids, np.int64))
    out = []
    for _ in range(n_new):
        out.append(int(np.argmax(lg)))
        ids.append(out[-1])
        lg, cache = eng.forward(np.array(ids, np.int64), cache)
    return eng.decode(out), time.time() - t0


eng = S.StreamEngine()
eng2 = S.StreamEngine()
c_out, c_dt = greedy(eng, True)
n_out, n_dt = greedy(eng2, False)
print("C  :", repr(c_out), f"{c_dt:.2f}s")
print("npy:", repr(n_out), f"{n_dt:.2f}s")
print("MATCH" if c_out == n_out else "MISMATCH")