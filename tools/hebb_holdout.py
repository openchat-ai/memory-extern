"""hebb_holdout.py — 大样本 holdout + 语义判据 (docs/HEB_EXPERIMENT.md §10.26.9).

为什么要这个:
  1. 旧口径 6 条 holdout -> 漏判 (采样噪声底 1/20, 贪心 20 条下 1L18 是 6/20)
  2. 20 条 holdout -> 噪声底 29pp, 配置之间不可分辨
     配对设计要分辨 ~3 条差异, 约需 80~100 条 (McNemar b≈10,c≈2 才 p<0.05)
  3. "污染"只比逐字差异, 而基座在这些提示上的输出本身就是垃圾
     -> 补**语义判据**: 输出是不是合法 Python (ast.parse)

用法:
  python tools/hebb_holdout.py --base            # 只算基座基线 + 可解析率
  python tools/hebb_holdout.py <a.gguf> <b.gguf> ...
"""
import argparse
import ast
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine, SRC

BASE = ("/data/data/com.termux/files/home/models/qxt/"
        "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
CACHE = "/data/data/com.termux/files/home/sram/data/holdout_base.json"

# 100 条代码提示: 覆盖函数/类/控制流/推导式/异常/文件/标准库/科学计算/字符串
HOLD = [
    "def factorial(n):", "def fib(n):", "def quicksort(arr):", "def merge(a, b):",
    "def is_prime(n):", "def gcd(a, b):", "def reverse_string(s):",
    "def count_words(text):", "def flatten(nested):", "def chunk(lst, n):",
    "class Point:\n    def __init__(", "class Node:\n    def __init__(self, v):",
    "class Stack:", "class Queue:", "class Rectangle:",
    "import os\nos.path.", "import json\njson.", "import re\nre.",
    "import math\nmath.", "import sys\nsys.", "import random\nrandom.",
    "import numpy as np\nnp.", "import pandas as pd\npd.",
    "from collections import defaultdict\ndefaultdict",
    "for i in range(10):", "for k, v in d.items():", "for x in lst:\n    ",
    "while True:", "while queue:", "if x is None:", "if not lst:",
    "try:\n    x = 1\nexcept:", "try:\n    f()\nexcept ValueError as e:",
    "with open('f') as f:", "with open('f', 'w') as f:\n    ",
    "return [x*2 for x in y]", "return {k: v for k, v in items}",
    "return sum(x for x in nums)", "x = {1: 2}", "x = [1, 2, 3]",
    "x = (1, 2, 3)", "x = 'hello'", "s = 'x' * 3", "s = f'{name}'",
    "assert x == y", "assert len(lst) == 3", "print('hello",
    "def main():\n    if __name__", "def main():\n    ",
    "result = []\nfor x in", "data = open(", "line = f.readline()",
    "text = f.read()", "lines = f.readlines()", "f.write('hello')",
    "np.array([1, 2, 3])", "np.zeros((3, 3))", "np.mean([1, 2, 3])",
    "df = pd.read_csv(", "df.head()", "df['col'].mean()",
    "plt.plot(", "torch.tensor(", "model.eval()", "loss.backward()",
    "optimizer.step()", "x = torch.randn(",
    "re.match(r'\\d+', s)", "re.findall(r'[a-z]+', s)", "re.sub(r'a', 'b', s)",
    "datetime.now()", "time.time()", "os.makedirs(p, exist_ok=True)",
    "os.remove(path)", "os.getcwd()", "shutil.copy(src, dst)",
    "json.dumps(obj, indent=2)", "json.loads(s)", "pickle.dump(obj, f)",
    "logging.info('x')", "logger.error(", "print(f'{x=}'",
    "def get(self):", "def set(self, v):", "return self.value",
    "self.x = x", "self._cache = {}", "raise ValueError('bad')",
    "raise KeyError('k')", "return None", "return True", "return False",
    "yield item", "async def fetch(url):", "await client.get(url)",
    "def gen():\n    for i in range", "lambda x: x * 2",
    "list(map(str, lst))", "filter(None, lst)", "sorted(lst, key=lambda x: x[1])",
    "zip(a, b)", "enumerate(lst)", "isinstance(x, int)",
    "def deco(f):\n    ", "@decorator\ndef g():",
    "if __name__ == '__main__':\n    ",
]


def gen_greedy(eng, prompt, n_new=12):
    ids = list(eng.encode(prompt))
    lg, cache = eng.forward(np.array(ids, np.int64))
    out = []
    for _ in range(n_new):
        t = int(np.argmax(lg))
        out.append(t)
        lg, cache = eng.forward(np.array([t], np.int64), cache)
    return eng.decode_text(out)


def ast_valid(prompt, cont):
    """语义判据: prompt+续写 能否被 Python 解析."""
    try:
        ast.parse(prompt + cont)
        return True
    except (SyntaxError, ValueError, MemoryError, RecursionError):
        return False


def ast_valid_cont(cont):
    """续写单独可解析 (有些续写是完整语句)."""
    try:
        ast.parse(cont)
        return True
    except (SyntaxError, ValueError, MemoryError, RecursionError):
        return False


def rep_count(text):
    toks = text.split()
    best = cur = 1
    for i in range(1, len(toks)):
        cur = cur + 1 if toks[i] == toks[i - 1] else 1
        best = max(best, cur)
    return best


def base_out(n_new=12):
    if os.path.exists(CACHE):
        with open(CACHE) as f:
            return json.load(f)
    E = StreamEngine(slim=BASE, src=SRC, n_ctx=512)
    outs = [gen_greedy(E, p, n_new) for p in HOLD]
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w") as f:
        json.dump(outs, f)
    return outs


def mcnemar(a, b):
    """配对: a/b 两个 0/1 序列. 返回 (b_only, c_only, p)."""
    from math import comb
    nb = sum(1 for x, y in zip(a, b) if x and not y)
    nc = sum(1 for x, y in zip(a, b) if y and not x)
    n = nb + nc
    if n == 0:
        return 0, 0, 1.0
    k = min(nb, nc)
    p = min(1.0, 2 * sum(comb(n, i) for i in range(k + 1)) / (2 ** n))
    return nb, nc, p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--base", action="store_true")
    ap.add_argument("--pairwise", action="store_true")
    args = ap.parse_args()

    base = base_out()
    bparse = [ast_valid(p, c) for p, c in zip(HOLD, base)]
    bcont = [ast_valid_cont(c) for c in base]
    brep = [rep_count(c) for c in base]
    print(f"[基座] {len(HOLD)} 条提示 | prompt+续写 可解析 {sum(bparse)}/{len(HOLD)} "
          f"({100*sum(bparse)/len(HOLD):.0f}%) | 续写单独可解析 {sum(bcont)}/{len(HOLD)} "
          f"({100*sum(bcont)/len(HOLD):.0f}%) | 平均 rep {np.mean(brep):.2f}", flush=True)

    if args.pairwise:
        D = "/data/data/com.termux/files/home/sram/data"
        vecs = {}
        for fn in sorted(os.listdir(D)):
            if fn.startswith("holdout_diff_"):
                with open(os.path.join(D, fn)) as f:
                    vecs[fn[len("holdout_diff_"):-len(".json")]] = json.load(f)
        names = list(vecs)
        print(f"[配对 McNemar] n={len(HOLD)}", flush=True)
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                b, c, p = mcnemar(vecs[names[i]], vecs[names[j]])
                print(f"  {names[i][:28]:30s} vs {names[j][:28]:30s} "
                      f"b={b} c={c} p={p:.4f} "
                      f"{'显著' if p < 0.05 else '不显著'}", flush=True)
        return 0

    if args.base or not args.files:
        return 0

    for path in args.files:
        E = StreamEngine(slim=path, src=SRC, n_ctx=512)
        outs = [gen_greedy(E, p, 12) for p in HOLD]
        diff = [o != b for o, b in zip(outs, base)]
        parse = [ast_valid(p, o) for p, o in zip(HOLD, outs)]
        cont = [ast_valid_cont(o) for o in outs]
        rep = [rep_count(o) for o in outs]
        newbad = [d and (b0 and not p0) for d, b0, p0 in zip(diff, bparse, parse)]
        newgood = [d and (not b0 and p0) for d, b0, p0 in zip(diff, bparse, parse)]
        print(f"\n=== {os.path.basename(path)} ===", flush=True)
        print(f"  逐字不同 {sum(diff)}/{len(HOLD)} | 可解析 {sum(parse)}/{len(HOLD)} "
              f"(基座 {sum(bparse)}) | 续写可解析 {sum(cont)}/{len(HOLD)} "
              f"(基座 {sum(bcont)}) | 变坏(可解析->不可) {sum(newbad)} | "
              f"变好 {sum(newgood)} | rep↑ {sum(1 for a, b in zip(rep, brep) if a > b)}",
              flush=True)
        with open(os.path.join("/data/data/com.termux/files/home/sram/data",
                               "holdout_diff_" + os.path.basename(path) + ".json"), "w") as f:
            json.dump(diff, f)
        for p, o, b, d, pr in zip(HOLD, outs, base, diff, parse):
            if d:
                print(f"    {p!r:34s} ast={pr} rep{brep[HOLD.index(p)]}->{rep[HOLD.index(p)]} "
                      f"{b[:26]!r} -> {o[:26]!r}", flush=True)
        del E
    return 0


if __name__ == "__main__":
    sys.exit(main())
