import sys, numpy as np
sys.path.insert(0,'tools')
from q1t_stream import StreamEngine, SRC
slim="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
eng=StreamEngine(slim=slim,src=SRC,n_ctx=256)
print("n_layer",eng.n_layer,"n_embd",eng.n_embd,"n_vocab",eng.n_vocab)
for nm in ("ffn_gate.weight","ffn_up.weight","ffn_down.weight","attn_q.weight"):
    sm=eng.mat[f"blk.2.{nm}"]
    print(f"blk.2.{nm}: n_in={sm.n_in} n_out={sm.n_out}")
print("tensor names sample:", [k for k in eng.mat if 'blk.2.' in k])
