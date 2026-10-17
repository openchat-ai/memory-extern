#!/data/data/com.termux/files/usr/bin/python3
"""mk_byte_data.py — 把 Q4T token 流解码回字节, 产出字节级训练数据.

动机(§33.21): Q4T 的 151K tokenizer 把 Python 切得太碎, V=2400 时
44% 的 token 无法表达, 连 'def add(a,b): return a+b' 都写不全(79% 覆盖).
字节级 V=257 覆盖率恒为 100%, 彻底消除 UNK 天花板.

编码: byte + 1, 留 0 给 UNK, 与 a3_pretrain.compress_vocab 的约定一致.
用法: python3 tools/mk_byte_data.py --tokens codeonly_full.npz --out code_bytes.npz
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", default="/data/data/com.termux/files/home/sram/"
                    "magicoder_a3.jsonl")
    ap.add_argument("--out", required=True)
    ap.add_argument("--max-bytes", type=int, default=8_000_000)
    a = ap.parse_args()

    # 直接读原始源码, 不走 Q4T tokenizer ——
    # StreamEngine.decode() 返回的是逐 token 的字节级标记(Ġ/Ċ), 不是还原后的文本,
    # 绕一圈反而要处理 BPE 反解. 训练数据本来就该来自原始 jsonl.
    import json
    buf = bytearray()
    with open(a.jsonl, encoding="utf-8") as f:
        for line in f:
            buf += json.loads(line)["code"].encode("utf-8")
            if len(buf) >= a.max_bytes:
                break
    b = np.frombuffer(bytes(buf[:a.max_bytes]), np.uint8).astype(np.int32) + 1
    np.savez(a.out, ids=b)
    u = len(np.unique(b))
    print(f"[bytes] 原始 Python 源码 -> {len(b):,} byte  ({a.out})")
    print(f"[bytes] 实际用到 {u} 个取值 -> compress_vocab 会把 V 压到 {u+1}")
    print(f"[bytes] 样本: {bytes(b[:120]-1).decode('utf-8','replace')!r}")


if __name__ == "__main__":
    main()
