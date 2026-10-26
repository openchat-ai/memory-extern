"""定位 (§11.2): 测 10 条事实的 key φ 余弦相似度.
若串扰源于 key 太像, 则 φ 两两相似度应显著 > 0 (论文前提是准正交)."""
import sys, numpy as np
sys.path.insert(0, 'tools')
from qxt_hebb import HebbInjector

FACTS = [
    ("def add(a, b):", "print"), ("def subtract(a, b):", "return"),
    ("def multiply(a, b):", "result"), ("import math", "sqrt"),
    ("import os", "path"), ("class Animal:", "def"),
    ("x = [1, 2, 3]", "for"), ("def main():", "if"),
    ("from sys import argv", "print"), ("with open('f') as fh:", "read"),
]
H = HebbInjector()
phis = {p: H.capture_phi(np.array(H.eng.encode(p), np.int64)) for p, _ in FACTS}
prompts = [p for p, _ in FACTS]

# 每层: 10x10 余弦矩阵, 取平均
print("=== 每层 φ 两两余弦相似度 (非对角均值) ===")
Mall = []
for i in range(H.N):
    P = np.stack([phis[p][i] for p in prompts])   # (10, F)
    Pn = P / np.linalg.norm(P, axis=1, keepdims=True)
    C = Pn @ Pn.T
    off = C[~np.eye(10, dtype=bool)]
    Mall.append(off)
    if i % 4 == 0 or i == H.N - 1:
        print(f"  layer{i:2d}: 非对角均值 {off.mean():+.3f}  最大 {off.max():+.3f}  最小 {off.min():+.3f}")
Mall = np.concatenate(Mall)
print(f"\n全部层合计: 非对角余弦 均值 {Mall.mean():+.3f}  中位 {np.median(Mall):+.3f}  最大 {Mall.max():+.3f}")
print(f"  |cos|>0.5 的比例: {(np.abs(Mall)>0.5).mean()*100:.1f}%")
print(f"  |cos|>0.9 的比例: {(np.abs(Mall)>0.9).mean()*100:.1f}%")
print("  (论文前提: 随机 A/G 时 φ 近似正交, 非对角 ~ 0)")
