"""hebb_memory.py — 运行时事实记忆层（零训练）.

背景（docs/HEB_EXPERIMENT.md §10.12）:
  FFN 权重写入只能占掉"下一个 token"，无法让事实在别处被查询（桥接 rank 425→37）。
  事实一旦在 KV/上下文路径上，引擎就会用它推理（Berlin rank 0）。
  => 本模块把事实做成**运行时注入**，而不是烘进 GGUF。

机制:
  1. 事实库: (key, value) —— key 是"事实的提问句"，value 是答案
  2. 检索: **token 级 IDF 加权重合** —— 年份/专名是低 df token，权重高
     （实测 φ-cosine 不可用: 同模板 key 的 cos ≈ 0.98，无关句反而分更高, §10.11.6）
  3. 注入: 检索到就把事实拼进提示, 交给原模型生成
  4. 阈值: 分数不够就**不注入**，退回 base 回答

用法:
  python tools/hebb_memory.py --demo
  from hebb_memory import HebbMemory
  m = HebbMemory().add("The country where the 1974 FIFA World Cup was held is", "Germany")
  m.answer("What is the capital city of that country?",
           context="The country where the 1974 FIFA World Cup was held is")
"""
import argparse
import json
import math
import os
import sys
from collections import Counter

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_write import HebbWriter

TEMPLATE = "{key} {value}.\n{q}\nAnswer:"


class HebbMemory:
    def __init__(self, n_ctx=512, threshold=0.35):
        self.H = HebbWriter(n_ctx=n_ctx)
        self.E = self.H.eng
        self.threshold = threshold
        self.facts = []
        self._toks = []
        self._df = Counter()

    def _tok(self, text):
        ids = list(self.E.encode(text))
        grams = {("t", x) for x in ids}
        grams |= {("b", a, b) for a, b in zip(ids, ids[1:])}
        return grams

    def add(self, key, value):
        self.facts.append({"key": key, "value": value})
        t = set(self._tok(key))
        self._toks.append(t)
        for x in t:
            self._df[x] += 1
        return self

    def load(self, path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    d = json.loads(line)
                    self.add(d["key"], d["value"])
        return self

    def save(self, path):
        with open(path, "w") as f:
            for d in self.facts:
                f.write(json.dumps(d, ensure_ascii=False) + "\n")

    def _idf(self, tok):
        n = len(self.facts)
        return math.log((n + 1) / (self._df.get(tok, 0) + 1)) + 1.0

    def _score(self, query, key_toks):
        q = self._tok(query)
        if not q:
            return 0.0
        # 未见过的 bigram/单 token = 库外信号 -> 硬拒绝 (防 1954 命中 1958)
        if any(self._df.get(t, 0) == 0 for t in q):
            return 0.0
        shared = sum(self._idf(t) for t in q & key_toks)
        total = sum(self._idf(t) for t in q)
        return shared / total if total else 0.0

    def retrieve(self, query, k=1):
        if not self.facts:
            return []
        sims = [(self._score(query, kt), i) for i, kt in enumerate(self._toks)]
        sims.sort(reverse=True)
        return [{"sim": s, **self.facts[i]} for s, i in sims[:k]]

    def answer(self, question, context=None, n_new=24, threshold=None):
        th = self.threshold if threshold is None else threshold
        hits = self.retrieve(context or question, k=1)
        best = hits[0] if hits else None
        if best is None or best["sim"] < th:
            prompt = question
            used = None
        else:
            prompt = TEMPLATE.format(key=best["key"], value=best["value"], q=question)
            used = best
        ids, _ = self.E.generate(prompt, n_new=n_new, temperature=0.01)
        return {"text": self.E.decode_text(ids), "used": used,
                "sim": None if best is None else best["sim"], "prompt": prompt}


FACTS = [
    ("The country where the 1958 FIFA World Cup was held is", "Sweden", "Stockholm"),
    ("The country where the 1962 FIFA World Cup was held is", "Chile", "Santiago"),
    ("The country where the 1966 FIFA World Cup was held is", "England", "London"),
    ("The country where the 1974 FIFA World Cup was held is", "Germany", "Berlin"),
    ("The country where the 1978 FIFA World Cup was held is", "Argentina", "Buenos Aires"),
    ("The country where the 1982 FIFA World Cup was held is", "Italy", "Rome"),
    ("The country where the 1986 FIFA World Cup was held is", "Mexico", "Mexico City"),
    ("The country where the 1990 FIFA World Cup was held is", "Italy", "Rome"),
    ("The country where the 1994 FIFA World Cup was held is", "United States", "Washington"),
    ("The country where the 1998 FIFA World Cup was held is", "France", "Paris"),
]

CTX = "The country where the {y} FIFA World Cup was held is"
Q_CAP = "What is the capital city of that country?"


def demo():
    m = HebbMemory()
    for key, val, _ in FACTS:
        m.add(key, val)
    print(f"[store] {len(m.facts)} 条事实", flush=True)

    ok = 0
    print("\n=== 桥接: 检索(上下文里的年份) -> 注入 -> 用事实答首都 ===", flush=True)
    for key, val, cap in FACTS:
        y = key.split("the ")[1].split(" ")[0]
        r = m.answer(Q_CAP, context=CTX.format(y=y))
        hit = (r["used"] is not None and r["used"]["key"] == key)
        good = hit and cap.lower() in r["text"].lower()
        ok += good
        print(f"  {y}  sim={r['sim']:.2f} 检索={'OK' if hit else 'WRONG'} "
              f"答={r['text'][:30]!r:34s} 期望{cap!r} {'OK' if good else 'FAIL'}", flush=True)
    print(f"[桥接] {ok}/{len(FACTS)}", flush=True)

    print("\n=== 直接召回 ===", flush=True)
    for key, val, _ in FACTS[:3]:
        y = key.split("the ")[1].split(" ")[0]
        r = m.answer(key, context=key, n_new=8)
        good = val.lower() in r["text"].lower()
        print(f"  {y} -> {r['text'][:26]!r:28s} 期望{val!r} {'OK' if good else 'FAIL'}", flush=True)

    print("\n=== 无关问句 (不应注入) ===", flush=True)
    r = m.answer("The color of the sky is", n_new=12)
    print(f"  sim={r['sim']:.2f} used={r['used']} gen={r['text']!r}", flush=True)
    print(f"  {'OK (未注入)' if r['used'] is None else 'FAIL (误注入)'}", flush=True)

    print("\n=== 库外年份 (不应注入) ===", flush=True)
    r = m.answer(Q_CAP, context=CTX.format(y="1954"), n_new=12)
    print(f"  sim={r['sim']:.2f} used={r['used']} gen={r['text']!r}", flush=True)
    print(f"  {'OK (未注入)' if r['used'] is None else 'FAIL (误注入)'}", flush=True)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--store")
    ap.add_argument("--q")
    ap.add_argument("--context")
    ap.add_argument("--threshold", type=float, default=0.35)
    args = ap.parse_args()
    if args.demo:
        return demo()
    m = HebbMemory(threshold=args.threshold)
    if args.store:
        m.load(args.store)
    if args.q:
        print(json.dumps(m.answer(args.q, context=args.context),
                         ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
