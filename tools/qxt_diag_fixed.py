"""修正 tokenizer: 用正确的 next-token (含前导空格) 重测 (§11.1)."""
import sys, numpy as np
sys.path.insert(0,'tools')
from qxt_hebb import HebbInjector, Fp32Mat
H=HebbInjector()

def write_ctx(prompt, target_str, c=5.0, layers=None):
    """target 取 encode(' '+target)[0] (词首空格). 返回 rank."""
    toks=np.array(H.eng.encode(prompt),np.int64)
    tgt=H.eng.encode(" "+target_str)[0]
    B=H._materialize()
    if layers is None: layers=list(range(H.N))
    phis=H.capture_phi(toks); v=H.embed(tgt)
    for i in layers:
        pk=phis[i]; dB=np.outer(pk,c*v)/(pk@pk)
        H.eng.mat[f"blk.{i}.ffn_down.weight"]=Fp32Mat(B[i]+dB.astype(np.float32))
    lo=H.forward(toks)
    return int((lo>lo[tgt]).sum()), H.eng.tok_list[int(lo.argmax())], tgt

for p,t in [("The capital of France is","Paris"),("def add(a, b):","print"),
            ("The quick brown fox","jumps")]:
    H.restore()
    r,top1,tid=write_ctx(p,t,c=5.0)
    print(f"{p!r} -> {t!r}(id {tid}): rank {r} top1 {top1!r}")
