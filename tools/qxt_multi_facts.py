"""多条事实并行写入: 测串扰 (§11.2 定位 + 侧支 #8).
用 qxt_hebb 库. 每条事实 = (不同 prompt) -> (不同 target token).
"""
import sys, numpy as np
sys.path.insert(0, 'tools')
from qxt_hebb import HebbInjector

# 事实设计: 每个 prompt 结构相似但语义不同, target 各异
FACTS = [
    ("def add(a, b):", "print"),
    ("def subtract(a, b):", "return"),
    ("def multiply(a, b):", "result"),
    ("import math", "sqrt"),
    ("import os", "path"),
    ("class Animal:", "def"),
    ("x = [1, 2, 3]", "for"),
    ("def main():", "if"),
    ("from sys import argv", "print"),
    ("with open('f') as fh:", "read"),
]

H = HebbInjector()
print(f"d={H.d} F={H.F} layers={H.N}")
print("\n=== 逐条写入 (增量), 每写一条测全部 ===")
print(f"{'M':>3} {'第M条rank':>10} {'已写入命中':>12} {'对照(随机)':>12}")
for m in range(1, len(FACTS) + 1):
    p, t = FACTS[m - 1]
    r_m, _ = H.write(p, t, c=5.0)
    hits = 0
    for pp, tt in FACTS[:m]:
        r, _ = H.rank_of(pp, tt)
        if r == 0:
            hits += 1
    # 对照: 同样 M 条, 但全用随机 val
    H.restore()
    for pp, tt in FACTS[:m]:
        H.write_random(pp, c=5.0, seed=hash(pp) & 0xffff)
    rh = 0
    for pp, tt in FACTS[:m]:
        r, _ = H.rank_of(pp, tt)
        if r == 0:
            rh += 1
    H.restore()
    print(f"{m:>3} {r_m:>10} {hits:>7}/{m:<4} {rh:>7}/{m:<4}")
