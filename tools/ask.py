#!/usr/bin/env python3
"""命令行问答: 检索 -> 注入上下文 -> 生成, 并打印溯源.

  python tools/ask.py "Who won the 1954 World Cup?"
  python tools/ask.py --mem data/mem_demo.txt --no-gen "capital of France"
事实文件: 每行 `key=value`, # 开头为注释.
"""
import sys, os, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_memory import HebbMemory

DEMO = [("The winner of the 1954 FIFA World Cup is", "Germany"),
        ("The winner of the 1958 FIFA World Cup is", "Brazil"),
        ("The winner of the 1962 FIFA World Cup is", "Brazil"),
        ("The winner of the 1970 FIFA World Cup is", "Brazil"),
        ("The capital of France is", "Paris"),
        ("The currency of Japan is", "yen")]


def load(path):
    facts = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            facts.append((k.strip(), v.strip()))
    return facts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("question")
    ap.add_argument("--mem", default="")
    ap.add_argument("--n-new", type=int, default=16)
    ap.add_argument("--no-gen", action="store_true")
    ap.add_argument("--resolve", default="latest", choices=["latest", "uses", "off"])
    a = ap.parse_args()

    facts = load(a.mem) if a.mem else DEMO
    m = HebbMemory(resolve=a.resolve)
    m.soft = True
    for k, v in facts:
        m.add(k, v)

    print(f"Q: {a.question}")
    print(f"  库: {len(facts)} 条" + (f"  冲突: {m.conflicts()}" if m.conflicts() else ""))
    hits = m.retrieve(a.question, k=1)
    h = hits[0] if hits else None
    if h is None:
        print("  检索: 空库")
    elif h["sim"] <= 0.0:
        print("  检索: 未命中 (没有可用的 key; 数字未存时会被守卫拒绝)")
    else:
        tag = "[歧义]" if h["ambiguous"] else ""
        tag += f"[{h['resolved']}]" if h.get("resolved") else ""
        print(f"  检索: {h['key']!r} -> {h['value']}  sim={h['sim']:.3f} {tag}")
    if a.no_gen:
        return
    info = m.answer(a.question, n_new=a.n_new)
    print(f"  路由: {info.get('route')}")
    print(f"  答: {info.get('text', '').strip()[:200]!r}")


if __name__ == "__main__":
    main()
