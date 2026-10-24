"""hebb_style.py — 第二个语义方向：代码 vs 散文（验证流程可复用）.

§10.20/10.21 只证明了"情感"一个方向。本节用同一套流程构建第二个方向，
检验它是不是通用机制，而不是对情感词表的偶然拟合。

用法:
  python tools/hebb_style.py --cls     # 构造句分类 (AUC)
  python tools/hebb_style.py --rank    # 候选择码 (随机方向对照)

对照 (docs/HEB_EXPERIMENT.md §10.24.2):
  随机方向 AUC 10 次: mean 0.531, max 0.940, 0 次达 1.000
  token 数基线 AUC 0.740 (代码带换行缩进) -> 所以必须再看长度方向 delta
  长度方向 delta 作用于 code/prose 仅 0.570, cos(style,length)=0.036
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_rerank import Reader, spearman
from hebb_steer import Steerer

LAYER = 18

PAIRS = [
    ("def add(a, b):\n    return a + b",
     "To add two numbers, write a function that returns their sum."),
    ("for i in range(10):\n    print(i)",
     "Loop from zero to nine and print each number."),
    ("items.sort(key=lambda x: x.age)",
     "Sort the list of people by their age."),
    ("with open(path) as f:\n    data = f.read()",
     "Open the file and read all of its contents."),
    ("if not os.path.exists(p):\n    os.makedirs(p)",
     "Create the directory if it does not already exist."),
    ("result = [x for x in nums if x > 0]",
     "Keep only the positive numbers from the list."),
    ("try:\n    run()\nexcept Exception as e:\n    log(e)",
     "Run the task and log any error that occurs."),
    ("return json.dumps(obj, indent=2)",
     "Convert the object to formatted JSON text."),
]

CODE = [
    "class Node:\n    def __init__(self, v):\n        self.v = v",
    "while queue:\n    node = queue.pop(0)",
    "df = pd.read_csv(path)",
    "cache[key] = value",
    "assert len(parts) == 3, 'bad input'",
    "async def fetch(url):\n    return await client.get(url)",
    "np.linalg.norm(v)",
    "if x is None:\n    return default",
    "raise ValueError('invalid')",
    "for k, v in d.items():\n    print(k, v)",
]

PROSE = [
    "Create a node that stores a value.",
    "Process the queue until it is empty.",
    "Load the table from a CSV file.",
    "Store the value in the cache under its key.",
    "Check that the input has exactly three parts.",
    "Fetch a URL without blocking the program.",
    "Compute the length of the vector.",
    "Return the default value when the input is missing.",
    "Report an error for invalid input.",
    "Print every key together with its value.",
]

RANK_Q = [
    ("How do I read a CSV file in Python?",
     "import pandas as pd\ndf = pd.read_csv('data.csv')",
     "You can use the pandas library to load the file."),
    ("How do I sort a list of dicts by one key?",
     "items.sort(key=lambda x: x['age'])",
     "Pass a key function that extracts the field to sort on."),
    ("How do I create a directory if it is missing?",
     "if not os.path.exists(p):\n    os.makedirs(p)",
     "Check whether the path exists and then create it."),
    ("How do I read a file into a string?",
     "with open(path) as f:\n    text = f.read()",
     "Open the file and call read to get its contents."),
    ("How do I ignore errors when running a task?",
     "try:\n    run()\nexcept Exception:\n    pass",
     "Wrap the call in a try block and swallow the error."),
    ("How do I convert a dict to JSON?",
     "import json\ns = json.dumps(obj, indent=2)",
     "Use the json module to serialise the object."),
]


def auc(pos, neg):
    return float(np.mean([[1.0 if a > b else 0.5 if a == b else 0.0
                           for b in neg] for a in pos]))


def classify(R):
    print("=== 代码 vs 散文: 构造句分类 (10 / 10) ===", flush=True)
    c = [R.score_mean(t) for t in CODE]
    p = [R.score_mean(t) for t in PROSE]
    print(f"  AUC={auc(c, p):.3f}  code={np.mean(c):+.3f} prose={np.mean(p):+.3f}",
          flush=True)
    rng = np.random.default_rng(0)
    keep = R.u
    R.u = rng.normal(0, 1, keep.shape)
    R.u /= np.linalg.norm(R.u)
    c2 = [R.score_mean(t) for t in CODE]
    p2 = [R.score_mean(t) for t in PROSE]
    R.u = keep
    print(f"  random AUC={auc(c2, p2):.3f}", flush=True)


def rank(R):
    print("=== 重排: 每题 4 候选 (2 码 2 散文), 取最高 ===", flush=True)
    hit = 0
    for q, code, prose in RANK_Q:
        cands = [(code, 1), ("Yes, you can do it like this.", -1),
                 (prose, -1), ("Here is an example for that task.", -1)]
        top = max(cands, key=lambda c: R.score_mean(c[0]))
        hit += top[1] == 1
        print(f"  {'CODE' if top[1] == 1 else 'PROSE'} {top[0][:40]!r}", flush=True)
    print(f"[命中 {hit}/{len(RANK_Q)}]  随机期望 {len(RANK_Q)/4:.1f}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cls", action="store_true")
    ap.add_argument("--rank", action="store_true")
    args = ap.parse_args()
    st = Steerer().build(PAIRS, [LAYER])
    R = Reader(st)
    if args.cls or not args.rank:
        classify(R)
    if args.rank:
        rank(R)
    return 0


if __name__ == "__main__":
    sys.exit(main())
