"""多条写入 v2: 一次物化, 累积写入 (不 restore), 只测已写入集."""
import sys, numpy as np, time
sys.path.insert(0,'tools')
from qxt_hebb import HebbInjector

FACTS = [
    ("def add(a, b):", "print"), ("def subtract(a, b):", "return"),
    ("def multiply(a, b):", "result"), ("import math", "sqrt"),
    ("import os", "path"), ("class Animal:", "def"),
    ("x = [1, 2, 3]", "for"), ("def main():", "if"),
    ("from sys import argv", "print"), ("with open('f') as fh:", "read"),
]
H = HebbInjector()
print(f"d={H.d} F={H.F} layers={H.N}"); sys.stdout.flush()

# 预物化一次
t0=time.time(); B=H._materialize(); print(f"[物化] {time.time()-t0:.1f}s"); sys.stdout.flush()

# 预计算每条的 phi (物化后原始权重)
phis={p:H.capture_phi(np.array(H.eng.encode(p),np.int64)) for p,_ in FACTS}
embeds={t:H.embed(H.eng.tok_to_id[t]) for _,t in FACTS}
print("[phi/embd 预计算完毕]"); sys.stdout.flush()

# 累积写入: 每写一条, 直接改 eng.mat 的 down, 不 restore
print(f"{'M':>3} {'第M条rank':>10} {'命中':>8} {'top1_token':>12}")
for m in range(1,len(FACTS)+1):
    from qxt_hebb import Fp32Mat
    for i in range(H.N):
        pk=phis[FACTS[m-1][0]][i]; denom=pk@pk
        v=embeds[FACTS[m-1][1]]
        # 叠加到当前 down 上
        cur=H.eng.mat[f"blk.{i}.ffn_down.weight"]
        W = cur.W if hasattr(cur,'W') else B[i]
        H.eng.mat[f"blk.{i}.ffn_down.weight"]=Fp32Mat(W + (np.outer(pk,5.0*v)/denom).astype(np.float32))
    hits=0
    for pp,tt in FACTS[:m]:
        r,_=H.rank_of(pp,tt)
        if r==0: hits+=1
    r_m,top1=H.rank_of(*FACTS[m-1])
    print(f"{m:>3} {r_m:>10} {hits:>5}/{m:<3} {top1!r:>12}"); sys.stdout.flush()
