"""找最少层仍 rank 0 (§10.5 后续: 缩小层数).

判据复用既有口径:
  事实: 2 条 (FACTS)
  holdout: 6 条 (HOLD), 与基线逐字比对
  通过 = 2/2 rank 0 且 holdout 0/6 污染

变量 = 层集合. 固定每层 c=20 (交付口径). 在 fp32 上扫, 不重打包.
"""
import sys, numpy as np
sys.path.insert(0, 'tools')
from qxt_hebb import HebbInjector, Fp32Mat

FACTS = [("The largest planet is", "Jupiter"),
         ("The color of the sky is", "blue")]
HOLD = ["def factorial(n):", "class Point:\n    def __init__", "import os\nos.path.",
        "for i in range(10):", "def quicksort(arr):", "import numpy as np\nnp."]
C = 20.0
N = 28


def apply(H, layers, phis_by_prompt):
    """写 FACTS 到指定层, c=C. 返回 deltas (未应用), 由 caller 决定."""
    B = H._materialize()
    deltas = {i: np.zeros_like(B[i]) for i in range(N)}
    for (prompt, target), phis in zip(FACTS, phis_by_prompt):
        tgt = H.target_id(target); v = H.embed(tgt)
        for i in layers:
            pk = phis[i]
            deltas[i] += np.outer(pk, C * v) / (pk @ pk)
    return deltas


def evaluate(H, deltas):
    """应用 deltas -> 测 rank + holdout. 之后 restore."""
    B = H._materialize(); layers = [i for i in deltas if np.any(deltas[i])]
    for i in layers:
        H._set_down(i, (B[i] + deltas[i]).astype(np.float32))
    ranks, gens, hold = [], [], []
    for prompt, target in FACTS:
        toks = np.array(H.eng.encode(prompt), np.int64); tgt = H.target_id(target)
        lo = H.forward(toks)
        ranks.append(int((lo > lo[tgt]).sum()))
        gens.append(H.gen_text(prompt, n_new=14))
    for p in HOLD:
        hold.append(H.gen_text(p, n_new=20))
    H.restore(layers)
    return ranks, gens, hold


def main():
    H = HebbInjector(n_ctx=512)
    phis_by_prompt = [H.capture_phi(np.array(H.eng.encode(p), np.int64)) for p, _ in FACTS]
    base_hold = [H.gen_text(p, n_new=20) for p in HOLD]
    base_ranks = [H.rank_of(p, t)[0] for p, t in FACTS]
    print(f"[基线] ranks={base_ranks}", flush=True)
    for p, b in zip(HOLD, base_hold):
        print(f"  base {p!r:30s} -> {b!r}", flush=True)

    # 扫描: 最后 k 层
    print("\n=== 最后 k 层, 每层 c=20 ===", flush=True)
    for k in (1, 2, 3, 4, 5, 6, 8, 10):
        layers = list(range(N - k, N))
        d = apply(H, layers, phis_by_prompt)
        ranks, gens, hold = evaluate(H, d)
        polluted = sum(1 for a, b in zip(hold, base_hold) if a != b)
        ok = all(r == 0 for r in ranks) and polluted == 0
        print(f"  最后{k:2d}层: ranks={ranks} 污染={polluted}/6 "
              f"{'✓通过' if ok else ''}", flush=True)
        print(f"        gen0={gens[0]!r}", flush=True)
        if polluted:
            for p, a, b in zip(HOLD, hold, base_hold):
                if a != b:
                    print(f"        污染 {p!r} -> {a!r}", flush=True)


if __name__ == "__main__":
    main()
