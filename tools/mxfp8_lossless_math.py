#!/usr/bin/env python3
"""mxfp8_lossless_math.py — 纯数学推导(不依赖任何数据): 8bit MXFP8 能否无损装 e6m7.

定理: 值 v 能用 MXFP8 表示 ⟺ v = q × 2^n, 其中奇部 q ∈ MXFP8 尾数可表达集合.
  块尺度 scale=2^s 只移动指数窗口, 不改变奇部 → 无损判据仅取决于奇部 q.

e6m7 任意值 = (128+m) × 2^(e-7), m∈[0,127], e∈[0,63] → 奇部 = odd(128+m) ∈ 1..255.
MXFP8-E4M3 值 = (8+m') × 2^(k-3), 8+m' ∈ {8..15} → 奇部 q ∈ {1,3,5,7,9,11,13,15}.
MXFP8-E5M2: 1+m'/4, 4+m'∈{4..7} → 奇部 {1,3}? 4,5,6,7 → 1,5,3,7 → {1,3,5,7}.
MXFP8-E6M1: 1+m'/2, 2+m'∈{2..3} → {1,3}.

无损 ⟺ 每个权重的奇部落在上述集合内. dense 是稠密实数值 →
  落在集合外的概率 ~1-集合密度. 覆盖率由格式结构直接算出, 无需测数据.
"""
import math

def e6m7_odd_m_values(limit=255):
    """e6m7 全集中可无损表示所需的 m 集合: 使 odd(128+m) 落进 max q."""
    return None

def count_coverage(q_set):
    """e6m7 全集中奇部 ∈ q_set 的值数量 / 16384."""
    cnt = 0
    total = 0
    allowed = set(q_set)
    for e in range(64):
        for m in range(128):
            total += 1
            q = 128 + m
            while q % 2 == 0:
                q //= 2
            if q in allowed:
                cnt += 1
    return cnt, total

def q_sets_for(E, M):
    """MXFP8 (E,M) 的可表达奇部集合."""
    if (E, M) == (4, 3):
        return {1, 3, 5, 7, 9, 11, 13, 15}
    if (E, M) == (5, 2):
        return {1, 3, 5, 7}
    if (E, M) == (6, 1):
        return {1, 3}
    return None

def main():
    print("纯数学推导: 8bit MXFP8 无损装 e6m7 (与数据无关)")
    print("="*60)
    print(f"{'格式':<8} {'可表达奇部':<28} {'e6m7值覆盖率'}")
    for (E, M) in [(4, 3), (5, 2), (6, 1)]:
        q = q_sets_for(E, M)
        cnt, total = count_coverage(q)
        # 数学上闭式: 覆盖率 = |q|/128 (仅奇部密度), 验证枚举
        closed = len(q) / 128.0
        print(f"E{E}M{M}    {sorted(q)!s:<26} {cnt}/{total} = {cnt/total*100:.2f}%  (闭式 {closed*100:.2f}%)")
    print()
    print("推论(纯数学, 无需测量):")
    print("  - 无损 ⟺ 每个权重的奇部 ∈ MXFP8 可表达集合")
    print("  - dense 权重是稠密实数值, 奇部均匀落在 1..255 → 触发集合外的概率 ≈ 1 - 覆盖率")
    print("  - 故对普通 dense, 8bit MXFP8 无损装 e6m7 在数学上不可行")
    print("  - 唯一例外: 权重全部来自 q≤15 的稀疏格点(如合成/高度结构化数据)")

if __name__ == "__main__":
    main()