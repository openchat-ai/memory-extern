"""命令行: 构建/查询/评估赫布式检索记忆 (无训练, 无外部 embedding 模型).

    python tools/retr_ask.py --build          # 从 data/retr_facts.txt 建索引
    python tools/retr_ask.py "What city is the capital of France?"
    python tools/retr_ask.py --eval           # 全部事实的改写查询, 报 top1
"""
import argparse
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FACTS = os.path.join(HERE, "data", "retr_facts.txt")
INDEX = os.path.join(HERE, "data", "retr_index.npz")


def load_facts(path=FACTS):
    rows = []
    with open(path, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            parts = [x.strip() for x in ln.split("|")]
            rows.append(parts)
    return rows


def build(facts, index):
    rows = load_facts(facts)
    m = RetrievalMemory(index)
    if len(m):
        print(f"[skip] {index} 已存在 {len(m)} 条, 删除后重建")
        return
    t0 = time.time()
    for n, row in enumerate(rows, 1):
        m.add(row[0], row[1])
        if n % 10 == 0:
            el = time.time() - t0
            print(f"  {n}/{len(rows)}  {el:.0f}s", flush=True)
    m.save(index)
    print(f"[done] {len(m)} 条, {time.time()-t0:.0f}s -> {index}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("query", nargs="*")
    ap.add_argument("--build", action="store_true")
    ap.add_argument("--eval", action="store_true")
    ap.add_argument("--facts", default=FACTS)
    ap.add_argument("--index", default=INDEX)
    ap.add_argument("--top", type=int, default=3)
    a = ap.parse_args()

    if a.build:
        build(a.facts, a.index)
        return
    m = RetrievalMemory(a.index)
    if not len(m):
        sys.exit(f"索引不存在: {a.index}  (先 --build)")
    if a.eval:
        rows = [r for r in load_facts(a.facts) if len(r) >= 3]
        hits = 0
        per = {}
        for key, val, para in rows:
            got = m.query(para, top=1)[0][0]
            ok = (got == key)
            hits += ok
            attr = key.split()[1] if key.startswith("The ") else key.split()[0]
            per.setdefault(attr, [0, 0])
            per[attr][0] += ok
            per[attr][1] += 1
        print(f"top1 {hits}/{len(rows)} = {hits/len(rows)*100:.1f}%  (N={len(m)})")
        for k, (h, n) in per.items():
            print(f"  {k:10s} {h}/{n}")
        return
    q = " ".join(a.query)
    print(f"[query] {q}")
    for key, val, sc in m.query(q, top=a.top):
        print(f"  {sc:.4f}  {val:16s} <- {key}")


if __name__ == "__main__":
    main()
