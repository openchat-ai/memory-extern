import sys, numpy as np, shutil, time
sys.path.insert(0,'tools')
import qxt_repack as RP
from q1t_stream import StreamEngine, SRC, read_packslim
from qxt_hebb import HebbInjector
BASE="/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf"
OUT="/data/data/com.termux/files/home/models/qxt/rStar-Coder-hebbit.gguf"
H=HebbInjector(n_ctx=512); E=H.eng
meta,by=read_packslim(BASE); cb=np.asarray(meta["codebook"],np.float32)
FACTS=[("The largest planet is","Jupiter"),("The color of the sky is","blue")]
START, C = 18, 20.0
B=H._materialize(); deltas={i:np.zeros_like(B[i]) for i in range(28)}
for prompt,target in FACTS:
    toks=np.array(E.encode(prompt),np.int64); tgt=H.target_id(target)
    phis=H.capture_phi(toks); v=H.embed(tgt)
    for i in range(START,28): pk=phis[i]; deltas[i]+=np.outer(pk,C*v)/(pk@pk)
t0=time.time(); shutil.copyfile(BASE,OUT)
with open(OUT,"r+b") as f:
    for i in range(START,28):
        e=by[f"blk.{i}.ffn_down.weight"]; W=RP.dequant_tensor(BASE,e,cb)
        f.seek(e["offset"]); f.write(RP.quant_tensor(W+deltas[i].astype(np.float32),cb))
print(f"[交付] {len(FACTS)} 条事实, 层 {START}-27, c={C}  {time.time()-t0:.0f}s -> {OUT}",flush=True)
Ex=StreamEngine(slim=OUT,src=SRC,n_ctx=512)
print("[事实命中]",flush=True)
for prompt,target in FACTS:
    toks=np.array(Ex.encode(prompt),np.int64); tgt=H.target_id(target)
    lo,_=Ex.forward(toks); r=int((lo>lo[tgt]).sum())
    g=Ex.decode_text(Ex.generate(prompt,n_new=12,temperature=0.01)[0])
    print(f"  {prompt!r:26s}-> {target!r:8s} rank {r} gen {g!r}",flush=True)
print("[无关 prompt 保持]",flush=True)
for p in ["def factorial(n):","class Point:\n    def __init__","import os\nos.path."]:
    g=Ex.decode_text(Ex.generate(p,n_new=20,temperature=0.01)[0])
    print(f"  {p!r:28s} -> {g!r}",flush=True)
