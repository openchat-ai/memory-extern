#!/usr/bin/env python3
"""
lru_ref.py — 大容量 LRU 参考重放 K3 trace，扫容量验证命中率平台。

白皮书 §5.7：LRU 命中率上限 36.3%（=1-1/1.57 复用因子），与真机
8~64 GB 恒 36.24% 吻合。这里用真 LRU（Python 计数/时间戳）扫容量，
确认"命中率平台"由结构决定（够大容量买不到更多跨批复用）。

用法：python3 lru_ref.py [trace.txt] [容量列表]
"""
import sys
from collections import OrderedDict

def lru_hitrate(path, cap):
    """真 LRU：cap 个槽。OrderedDict 维护访问序，命中即移至最新。"""
    cache = OrderedDict()
    hits = 0
    n = 0
    with open(path) as f:
        for line in f:
            k = int(line)
            n += 1
            if k in cache:
                hits += 1
                cache.move_to_end(k)
            else:
                if len(cache) >= cap:
                    cache.popitem(last=False)
                cache[k] = None
    return hits / n

def main():
    path = "k3_trace.txt"
    caps = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]
    if len(sys.argv) > 1:
        path = sys.argv[1]
    if len(sys.argv) > 2:
        caps = [int(x) for x in sys.argv[2].split(",")]

    print(f"LRU 容量扫描: {path}")
    for c in caps:
        hr = lru_hitrate(path, c)
        print(f"  cap={c:>6}  hit={hr*100:6.2f}%")

if __name__ == "__main__":
    main()