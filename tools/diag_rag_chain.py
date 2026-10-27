"""§10.39 真 RAG 链路: 激活检索(88.9%) + 0.6B 生成, 四条件.

A 真检索: 检索到的事实作 context, 答对了没有?
B 错 context: 给一条别的事实, 模型是盲从还是纠正?
C 无 context: 不给事实, 会不会编?
D 干扰: 正确事实 + 3 条同类干扰, 选得对吗?
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from retr_memory import RetrievalMemory
from hebb_write import HebbWriter
from retr_ask import load_facts

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INDEX = os.path.join(HERE, "data", "retr_index.npz")
N_NEW = 5
PICK = ["France", "Japan", "Brazil"]


def norm(s):
    return "".join(ch.lower() if ch.isalnum() else " " for ch in s).split()


def hit(text, value):
    t, v = norm(text), norm(value)
    if not v:
        return False
    joined = " ".join(t)
    if " ".join(v) in joined:
        return True
    return bool(v) and len(v[-1]) >= 4 and v[-1] in t


def main():
    rows = load_facts()
    by_country = {}
    for key, val, para in rows:
        for c in PICK:
            if f" {c} " in key or key.endswith(c):
                by_country.setdefault(c, []).append((key, val, para))
    facts = [r for c in PICK for r in by_country.get(c, [])][:6]
    pool_vals = [r[1] for r in rows if len(r) >= 3]
    pool = [r for r in rows if len(r) >= 3]
    print(f"[facts] 选中 {len(facts)} 条 (每国 3 属性)", flush=True)

    m = RetrievalMemory(INDEX)
    print(f"[index] {len(m)} 条", flush=True)
    E = HebbWriter().eng
    print("[model] 0.6B Q4T 已加载", flush=True)

    def gen(prompt):
        ids = list(E.encode(prompt))
        lg, cache = E.forward(np.array(ids, np.int64))
        out = []
        for _ in range(N_NEW):
            t = int(np.argmax(lg))
            out.append(t)
            ids.append(t)
            lg, cache = E.forward(np.array(ids, np.int64), cache)
        return E.decode_text(out)

    def prompt_of(ctx, q):
        body = "\n".join(f"Fact: {k} {v}." for k, v in ctx) if ctx else ""
        return (body + "\n" if body else "") + f"Question: {q}\nAnswer:"

    t0 = time.time()
    A = {"gold": 0, "top1": 0, "other": 0}
    B = {"follow": 0, "correct": 0, "other": 0}
    C = {"gold": 0, "pool": 0, "other": 0}
    D = {"gold": 0, "other": 0}
    retr_ok = 0
    samples = []
    for i, (key, val, para) in enumerate(facts):
        gotk, gotv, _ = m.query(para, top=1)[0]
        retr_ok += (gotk == key)
        # A: 真检索结果作 context
        g = gen(prompt_of([(gotk, gotv)], para))
        if hit(g, val):
            A["gold"] += 1
        elif hit(g, gotv):
            A["top1"] += 1
        else:
            A["other"] += 1
        if i < 2:
            samples.append(("A", para, g))
        # B: 错 context (循环取另一条事实)
        wk, wv, _ = facts[(i + 5) % len(facts)]
        g = gen(prompt_of([(wk, wv)], para))
        if hit(g, wv):
            B["follow"] += 1
        elif hit(g, val):
            B["correct"] += 1
        else:
            B["other"] += 1
        # C: 无 context
        g = gen(prompt_of([], para))
        if hit(g, val):
            C["gold"] += 1
        elif any(hit(g, v) for v in pool_vals if v != val):
            C["pool"] += 1
        else:
            C["other"] += 1
        # D: 正确 + 3 条同类干扰
        attr = key.split()[1]
        dis = [r for r in pool if r[0].split()[1] == attr and r[0] != key][:3]
        ctx = [(key, val)] + [(k, v) for k, v, _ in dis]
        g = gen(prompt_of(ctx, para))
        D["gold" if hit(g, val) else "other"] += 1
        print(f"  {i+1}/{len(facts)} {attr:8s} {val:9s} retr={'ok ' if gotk==key else 'MISS'}"
              f"  A={A['gold']}/{i+1} B_follow={B['follow']} C_gold={C['gold']}"
              f" D={D['gold']}/{i+1}  {time.time()-t0:.0f}s", flush=True)

    n = len(facts)
    print(f"\n检索 top1 {retr_ok}/{n} = {retr_ok/n*100:.0f}%")
    print(f"A 真检索 context: 答对 {A['gold']}/{n} | 答成检索值 {A['top1']} | 其它 {A['other']}")
    print(f"B 错 context:     盲从 {B['follow']}/{n} | 仍答对 {B['correct']} | 其它 {B['other']}")
    print(f"C 无 context:     答对 {C['gold']}/{n} | 编出池内事实 {C['pool']} | 其它 {C['other']}")
    print(f"D 事实+3 干扰:    答对 {D['gold']}/{n}")
    for tag, q, g in samples:
        print(f"[样例{tag}] Q: {q}\n         A: {g.strip()!r}")


if __name__ == "__main__":
    main()
