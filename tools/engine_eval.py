#!/data/data/com.termux/files/usr/bin/python3
"""engine_eval.py — 用 StreamEngine 跑 1+1=? 贪心 24 tok, 输出指标+文本+耗时."""
import sys, os, time
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine

prompt = "1+1=?"
n_new = 24
eng = StreamEngine()
ids = list(eng.encode(prompt))
print("prompt ids:", ids, flush=True)
t0 = time.time()
lg, cache = eng.forward(np.array(ids, np.int64))
t_prefill = time.time() - t0
out = []
t_gen = 0.0
for k in range(n_new):
    t1 = time.time()
    top = int(np.argmax(lg))          # 贪心, 对齐官方 --temp 0
    out.append(top)
    ids.append(top)
    lg, cache = eng.forward(np.array(ids, np.int64), cache)
    t_gen += time.time() - t1
text = eng.decode(out)
print("out ids:", out, flush=True)
print("text:", repr(text), flush=True)
print(f"prefill: {len(prompt)} tok in {t_prefill:.2f}s ({len(prompt)/t_prefill:.2f} tok/s)", flush=True)
print(f"gen: {n_new} tok in {t_gen:.2f}s ({n_new/t_gen:.2f} tok/s, {t_gen/n_new*1000:.0f}ms/tok)", flush=True)