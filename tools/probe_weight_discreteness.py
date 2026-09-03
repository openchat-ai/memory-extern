#!/usr/bin/env python3
"""probe_weight_discreteness.py — 判定任意专家权重是否可"公式化"压缩。

判据(通用, 与格式无关):
  1. 唯一数值数 k 远小于元素数 n → 可无损查表压缩 (log2(k) b/w)
  2. 唯一值是否 二幂×小数 (k·2^e) → 可移位GEMV, 无解压直接算
  3. 若 k·2^e 结构成立 + k 少 → 就是"用公式算每个权重"的钥匙

用法: python3 probe_weight_discreteness.py <权重文件路径> [dtype]
  读入 float32 权重 blob(裸二进制), 数唯一值并检测二幂结构。
  若权重是整字节(如 GGUF 提取的 Q4 打包), 需先解包成 float32 再喂入。
"""
import sys
import math
import numpy as np

def is_power_of_two_int(k, tol=0.5):
    """k 是否接近小整数 {1,3,5,7,...} 而非任意小数"""
    k = abs(k)
    for t in [1, 3, 5, 7, 9]:
        if abs(k - t) < tol:
            return True
    return False

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = sys.argv[1]
    dtype = np.float32 if len(sys.argv) < 3 else np.dtype(sys.argv[2])

    raw = np.fromfile(path, dtype=dtype)
    n = raw.size
    print(f"文件: {path}  元素: {n:,}  dtype: {dtype}")

    vals, counts = np.unique(raw, return_counts=True)
    k = len(vals)
    print(f"\n[判据1] 唯一数值数: {k:,}  ({k/n*100:.3f}%)")
    print(f"  → 若 k<<n, 每元素只需 log2(k)={np.ceil(np.log2(k)) if k>1 else 1:.0f} 位索引"
          f" (vs fp32 32b), 压缩比 {32/max(1,np.ceil(np.log2(k))):.2f}x 无损")

    # 判据2: 是否 二幂(小整数 × 2^e) 结构
    print("\n[判据2] 二幂结构检测 (k·2^e, k奇整数, e整数)")
    nonzero = vals[vals != 0]
    # 对全部唯一值逐一检验
    struct_ok = int((vals == 0).sum())
    for v in nonzero:
        av = abs(v)
        hit = False
        for kk in [1, 3, 5, 7]:
            for ee in range(-16, 4):
                if abs(av - kk * (2.0 ** ee)) < 1e-9 * max(1.0, abs(av)):
                    hit = True
                    break
            if hit:
                break
        if hit:
            struct_ok += 1
    ratio = struct_ok / len(vals)
    print(f"  唯一值中满足 k·2^e 的比例: {ratio*100:.1f}%")
    if ratio > 0.9:
        print(f"  ✓ 强二幂结构 → 移位GEMV(乘法=移位), 无解压直接算")
        print(f"  示例唯一值: {[float(x) for x in vals[vals!=0][:6]]}")
    else:
        print(f"  ✗ 非二幂结构 (尾数非小整数), 需要乘法GEMV, 公式化价值降低")

    print("\n[结论]")
    if k / n < 0.01 and ratio > 0.9:
        print("  高离散 + 二幂结构 → 专家权重可公式化: 小查表 + 移位GEMV, 高压缩比+免解压")
    elif k / n < 0.01:
        print("  高离散但非二幂 → 可查表压缩, 但GEMV仍需乘法")
    else:
        print("  连续分布 → 无离散结构, 公式化压缩不适用")

if __name__ == "__main__":
    main()