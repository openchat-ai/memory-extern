"""修正后: 用语义差异大的 key 重跑多条写入.
key 选自不同领域 (h 余弦 +0.28), 而非模板相同 (0.894)."""
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
    ("Hello world!", "\n"),
    ("def fibonacci(n):", "if"),
    ("password = ", "input"),
    ("total = sum", "("),
]
H = HebbInjector()
print(f"d={H.d} F={H.F} layers={H.N}"); sys.stdout.flush()
t0 = time.time(); B = H._materialize(); print(f"[物化] {time.time()-t0:.0f}s"); sys.stdout.flush()

phis = {p: H.capture_phi(np.array(H.eng.encode(p), np.int64)) for p, _ in FACTS}
def tgt_id(t):
    return H.eng.encode(t)[0]
embeds = {t: H.embed(tgt_id(t)) for _, t in FACTS}
print("[预计算完毕]"); sys.stdout.flush()

print(f"{'M':>3} {'第M条rank':>10} {'命中':>8} {'top1':>10}")
for m in range(1, len(FACTS) + 1):
    p_last, t_last = FACTS[m - 1]
    for i in range(H.N):
        pk = phis[p_last][i]; denom = pk @ pk; v = embeds[t_last]
        cur = H.eng.mat[f"blk.{i}.ffn_down.weight"]
        W = cur.W if hasattr(cur, 'W') else B[i]
        H.eng.mat[f"blk.{i}.ffn_down.weight"] = Fp32Mat(
            W + (np.outer(pk, 5.0 * v) / denom).astype(np.float32))
    hits = sum(1 for pp, tt in FACTS[:m] if H.rank_of(pp, tgt_id(tt))[0] == 0)
    r_m, top1 = H.rank_of(p_last, tgt_id(t_last))
    print(f"{m:>3} {r_m:>10} {hits:>5}/{m:<3} {top1!r:>10}"); sys.stdout.flush()
