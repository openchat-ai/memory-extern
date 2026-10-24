"""hebb_deliver.py — 赫布写入 (hebb) 交付器 (2026-10-21).

背景 (docs/HEB_EXPERIMENT.md §10.9):
  旧交付用 18-27 c=20 (总振幅 200) -> holdout 3/6 污染;
  单层 27 c=40 -> 2/6, 且**单层没有干净窗口**.
  实测干净窗口: 18-22 c∈[5,20] / 18-27 c∈[2,8]  (总振幅 20~100).

本工具:
  1. 从 BASE packslim 算 6 条 holdout 基线 (逐字)
  2. fp32 上按 norm 配方 (v⊗φ/|φ|²) 造 Δ
  3. 重打包 (Q4T 重新量化) 到新 GGUF
  4. **端到端在打包后的 GGUF 上验收** (不信任 fp32 中间结果):
       事实 2/2 rank 0  且  6 条 holdout 逐字与基线一致

用法:
  python tools/hebb_deliver.py --layers 18-22 --c 8 --out /path/cand.gguf

⚠ 口径提醒 (docs/HEB_EXPERIMENT.md §10.26.5):
  本工具的 holdout 判据是 **6 条 + 采样**, 会漏判 —— 采样噪声底本身 1/20,
  20 条 + 贪心下 1L18 是 6/20 污染. **以 tools/hebb_verify.py (20 条 + 贪心)
  为准**, 本工具的 "PASS" 不代表干净.
"""
import argparse, os, shutil, sys, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qxt_repack as RP
from q1t_stream import StreamEngine, SRC, read_packslim
from hebb_write import HebbWriter

BASE = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
FACTS = [("The largest planet is", "Jupiter"), ("The color of the sky is", "blue")]
HOLD = ["def factorial(n):", "class Point:\n    def __init__", "import os\nos.path.",
        "for i in range(10):", "def quicksort(arr):", "import numpy as np\nnp."]


def gen(eng, prompt, n_new=12, temperature=0.01):
    ids, _ = eng.generate(prompt, n_new=n_new, temperature=temperature)
    return eng.decode_text(ids)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--layers", default="18-22", help="如 18-22 或 18,19,20")
    ap.add_argument("--c", type=float, default=8.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--base", default=BASE)
    args = ap.parse_args()

    if "-" in args.layers:
        a, b = args.layers.split("-")
        layers = list(range(int(a), int(b) + 1))
    else:
        layers = [int(x) for x in args.layers.split(",")]
    C = args.c
    print(f"[cfg] layers={layers} c={C} 总振幅={C*len(layers):g}", flush=True)

    # 1) 基线 holdout (从 BASE 文件)
    Ex0 = StreamEngine(slim=args.base, src=SRC, n_ctx=512)
    base_hold = [gen(Ex0, p) for p in HOLD]
    del Ex0

    # 2) fp32 上造 Δ
    H = HebbWriter(n_ctx=512)
    E = H.eng
    meta, by = read_packslim(args.base)
    cb = np.asarray(meta["codebook"], np.float32)
    # 不调用 H._materialize() (会物化 28 层 = 344MB, 本机内存不足会 swap 颠簸);
    # 打包时的原始权重由 RP.dequant_tensor 从文件现取, 这里只需 Δ 的形状.
    deltas = {i: np.zeros((H.F, H.d), np.float32) for i in layers}
    for prompt, target in FACTS:
        toks = np.array(E.encode(prompt), np.int64)
        tgt = H.target_id(target)
        phis = H.capture_phi(toks)
        v = H.embed(tgt)
        for i in layers:
            pk = phis[i]
            deltas[i] += np.outer(pk, C * v) / (pk @ pk)

    # 3) 重打包
    t0 = time.time()
    shutil.copyfile(args.base, args.out)
    with open(args.out, "r+b") as f:
        for i in layers:
            e = by[f"blk.{i}.ffn_down.weight"]
            W = RP.dequant_tensor(args.base, e, cb)
            f.seek(e["offset"])
            f.write(RP.quant_tensor(W + deltas[i].astype(np.float32), cb))
    print(f"[repack] {len(layers)} 层 {time.time()-t0:.1f}s -> {args.out}", flush=True)

    # 4) 端到端验收 (在打包后的 GGUF 上)
    Ex = StreamEngine(slim=args.out, src=SRC, n_ctx=512)
    ok = True
    print("[事实]", flush=True)
    for prompt, target in FACTS:
        toks = np.array(Ex.encode(prompt), np.int64)
        tgt = H.target_id(target)
        lo, _ = Ex.forward(toks)
        r = int((lo > lo[tgt]).sum())
        g = gen(Ex, prompt, 12)
        good = (r == 0)
        ok &= good
        print(f"  {prompt!r:26s} -> {target!r:8s} rank {r} {'OK' if good else 'FAIL'} "
              f"gen {g!r}", flush=True)
    print("[holdout 6 条 (逐字 vs 基线)]", flush=True)
    pol = 0
    for p, b in zip(HOLD, base_hold):
        g = gen(Ex, p, 12)
        same = (g == b)
        if not same:
            pol += 1
        print(f"  {p!r:28s} {'same' if same else 'DIFF'}", flush=True)
        if not same:
            print(f"      base {b!r}", flush=True)
            print(f"      new  {g!r}", flush=True)
    print(f"[验收] facts_ok={ok} holdout_pol {pol}/6  "
          f"{'PASS' if (ok and pol == 0) else 'FAIL'}", flush=True)
    return 0 if (ok and pol == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
