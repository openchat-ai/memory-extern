"""诊断: France->Paris 单条写入 rank=1 不命中, 是 key 还是 value? (§11.2)"""
import sys, numpy as np
sys.path.insert(0,'tools')
from qxt_hebb import HebbInjector, Fp32Mat
H=HebbInjector()
p="The capital of France is"
toks=np.array(H.eng.encode(p),np.int64)
tgt=H.eng.encode("Paris")[0]
print(f"prompt {p!r} toks={toks.tolist()}")
print(f"target 'Paris' id={tgt}")

lo=H.forward(toks)
print(f"\n[基线] top5: {[(H.eng.tok_list[i], round(float(lo[i]),2)) for i in lo.argsort()[::-1][:5]]}")
print(f"  'Paris' logit {lo[tgt]:.3f} rank {int((lo>lo[tgt]).sum())}")

# 基线 top1 是什么?
top1=int(lo.argmax())
print(f"  top1 = {H.eng.tok_list[top1]!r} (id {top1}) logit {lo[top1]:.3f}")

# 写入, 扫描 c
B=H._materialize()
phis=H.capture_phi(toks)
v=H.embed(tgt)
print(f"\n[扫描 c] (写全层)")
for c in (1.0,2.0,5.0,10.0,20.0):
    for i in range(H.N):
        pk=phis[i]; dB=np.outer(pk,c*v)/(pk@pk)
        H.eng.mat[f"blk.{i}.ffn_down.weight"]=Fp32Mat(B[i]+dB.astype(np.float32))
    lo2=H.forward(toks)
    r=int((lo2>lo2[tgt]).sum())
    print(f"  c={c:5}: 'Paris' rank {r:5d}  top1 {H.eng.tok_list[int(lo2.argmax())]!r}")
    # 恢复
    for i in range(H.N): H.eng.mat[f"blk.{i}.ffn_down.weight"]=Fp32Mat(B[i])
