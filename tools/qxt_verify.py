"""qxt_verify.py — 对任意已打包 GGUF 做同口径验收 (不修改).

  python tools/qxt_verify.py <file.gguf> [...]
判据 (同 tools/qxt_deliver2.py, §11.3 同口径):
  事实 2 条 -> rank 0
  holdout 6 条 -> 逐字与 BASE packslim 基线一致
"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine, SRC
from qxt_hebb import HebbInjector

BASE = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
FACTS = [("The largest planet is", "Jupiter"), ("The color of the sky is", "blue")]
HOLD = ["def factorial(n):", "class Point:\n    def __init__", "import os\nos.path.",
        "for i in range(10):", "def quicksort(arr):", "import numpy as np\nnp."]


def gen(eng, prompt, n_new=12):
    ids, _ = eng.generate(prompt, n_new=n_new, temperature=0.01)
    return eng.decode_text(ids)


def main():
    H = HebbInjector(n_ctx=512)
    Ex0 = StreamEngine(slim=BASE, src=SRC, n_ctx=512)
    base_hold = [gen(Ex0, p) for p in HOLD]
    for path in sys.argv[1:]:
        Ex = StreamEngine(slim=path, src=SRC, n_ctx=512)
        print(f"===== {os.path.basename(path)} =====", flush=True)
        allok = True
        for prompt, target in FACTS:
            toks = np.array(Ex.encode(prompt), np.int64)
            tgt = H.target_id(target)
            lo, _ = Ex.forward(toks)
            r = int((lo > lo[tgt]).sum())
            g = gen(Ex, prompt, 12)
            allok &= (r == 0)
            print(f"  {prompt!r:26s} -> {target!r:8s} rank {r} "
                  f"{'OK' if r == 0 else 'FAIL'} gen {g!r}", flush=True)
        pol = 0
        for p, b in zip(HOLD, base_hold):
            g = gen(Ex, p, 12)
            if g != b:
                pol += 1
                print(f"  [DIFF] {p!r}\n      base {b!r}\n      new  {g!r}", flush=True)
        print(f"  holdout 污染 {pol}/6   -> "
              f"{'PASS' if (allok and pol == 0) else 'FAIL'}", flush=True)
        del Ex


if __name__ == "__main__":
    import numpy as np
    sys.exit(main())
