import sys
sys.path.insert(0,'tools')
import numpy as np
from q1t_stream import StreamEngine, SRC
slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim, src=SRC, n_ctx=512)
print("vocab",len(eng.tok_list),"layers",eng.n_layer,"bit",eng.bit, file=sys.stderr)
ids=eng.encode("def add(a, b):")
print("n_ids",len(ids), file=sys.stderr)
out,dt=eng.generate("def add(a, b):", n_new=16, temperature=0.01)
print("greedy ids:", out)
if hasattr(eng,'decode'): print("text:", repr(eng.decode(out)))
print("time %.1fs"%dt)
