"""修正 tokenizer 后, 重跑语义各异多条写入 (用库, target 自动加词首空格)."""
import sys, numpy as np, time
sys.path.insert(0, 'tools')
from qxt_hebb import HebbInjector, Fp32Mat

FACTS = [
    ("The capital of France is", "Paris"),
    ("import numpy as np", "array"),
    ("SELECT * FROM users", "WHERE"),
    ("class Animal:", "def"),
    ("The quick brown fox", "jumps"),
    ("x = [1, 2, 3]", "for"),
    ("Hello world!", "!"),
    ("def fibonacci(n):", "if"),
    ("password = ", "input"),
    ("total = sum", "("),
]
H = HebbInjector()
print(f"d={H.d} F={H.F} layers={H.N}"); sys.stdout.flush()
t0=time.time(); B=H._materialize(); print(f"[物化] {time.time()-t0:.0f}s"); sys.stdout.flush()

phis = {p: H.capture_phi(np.array(H.eng.encode(p), np.int64)) for p, _ in FACTS}
tgts = {t: H.target_id(t) for _, t in FACTS}
embeds = {t: H.embed(tgts[t]) for _, t in FACTS}
print("[预计算完毕, targets]", {t: (H.eng.tok_list[i], i) for t, i in tgts.items()}); sys.stdout.flush()

print(f"{'M':>3} {'第M条rank':>10} {'命中':>8} {'top1':>10}")
for m in range(1, len(FACTS) + 1):
    p_last, t_last = FACTS[m - 1]
    for i in range(H.N):
        pk = phis[p_last][i]; denom = pk @ pk; v = embeds[t_last]
        cur = H.eng.mat[f"blk.{i}.ffn_down.weight"]
        W = cur.W if hasattr(cur, 'W') else B[i]
        H.eng.mat[f"blk.{i}.ffn_down.weight"] = Fp32Mat(
            W + (np.outer(pk, 5.0 * v) / denom).astype(np.float32))
    hits = 0
    for pp, tt in FACTS[:m]:
        lo = H.forward(np.array(H.eng.encode(pp), np.int64)); tid = tgts[tt]
        if lo.argmax() == tid:
            hits += 1
    lo = H.forward(np.array(H.eng.encode(p_last), np.int64))
    r_m = int((lo > lo[tgts[t_last]]).sum())
    print(f"{m:>3} {r_m:>10} {hits:>5}/{m:<3} {H.eng.tok_list[int(lo.argmax())]!r:>10}"); sys.stdout.flush()
