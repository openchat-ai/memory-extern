#!/data/data/com.termux/files/usr/bin/python3
"""mk_arith_data.py — 生成加法训练数据(字节级).

动机(§36): 代码/聊天在这个量级做不了, 但"实现计算功能"可以 ——
输出空间只有 10 个数字, 必然全覆盖; 数据可无限生成, 没有欠训练; 
正确率可精确验证. 这是当前唯一三类前提同时满足的任务.

格式固定 12 字节一条, 便于按 seq_len 整齐切分:
    "A+B=C\\n"   A,B ∈ [100,499] (保证和 ∈ [200,998], 恒为 3 位)
编码沿用 mk_byte_data.py 的约定: 字节值 +1, 0 留给 UNK.
"""
import argparse

import numpy as np


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=1_300_000, help="题目数")
    ap.add_argument("--lo", type=int, default=100)
    ap.add_argument("--hi", type=int, default=499)
    a = ap.parse_args()

    rng = np.random.default_rng(12345)
    assert 2 * a.hi <= 999, "和可能超过 3 位, 请调小 hi(当前 hi*2 > 999)"
    buf = bytearray()
    for i in range(a.n):
        x = int(rng.integers(a.lo, a.hi + 1))
        y = int(rng.integers(a.lo, a.hi + 1))
        buf += f"{x}+{y}={x+y}\n".encode()
    arr = np.frombuffer(bytes(buf), np.uint8).astype(np.int32) + 1
    np.savez(a.out, ids=arr)
    print(f"[arith] {a.n:,} 题 -> {len(arr):,} 字节  ({a.out})")
    print(f"[arith] 取值 {len(np.unique(arr))} 种, 每题 12 字节")


if __name__ == "__main__":
    main()