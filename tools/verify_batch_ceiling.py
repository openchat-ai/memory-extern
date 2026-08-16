#!/usr/bin/env python3
"""verify_batch_ceiling.py — 批内去重上限 vs 实测 LRU 的闭环验证

结论（对 trace 直接推导，可复现）：
  100096 个请求，736 个 run（8 super-iter × 92 层）
  每 run 去重后的 distinct 总数 = 63824
  批复用因子 = 100096 / 63824 = 1.568
  批内去重上限 = 1 - 1/1.568 = 36.24%

  36.24% == 上游 kimi-k3 仓库实测 LRU 命中率（8~64GB 全平在 36.24%）
  => LRU 已吃满批内复用；Belady @64GB = 61.74% 多出的 25.5pt
     只能来自跨 run 的时间性复用（super-iter 周期重现）=> 方向 #1：周期保留策略。

用法：python3 verify_batch_ceiling.py [trace.bin]
"""
import struct
import sys

DEFAULT = "/data/data/com.termux/files/usr/tmp/opencode/kimi-k3-in-c-main/tests/fixtures/expert_trace.bin"


def load(path):
    raw = open(path, "rb").read()
    n = len(raw) // 8
    reqs = []
    for i in range(n):
        layer, exp = struct.unpack("<ii", raw[i * 8:i * 8 + 8])
        reqs.append((layer, exp))
    return reqs


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    reqs = load(path)

    runs = []
    cur = [reqs[0]]
    for r in reqs[1:]:
        if r[0] == cur[0][0]:
            cur.append(r)
        else:
            runs.append(cur)
            cur = [r]
    runs.append(cur)

    total = sum(len(r) for r in runs)
    distinct = sum(len(set(r)) for r in runs)
    factor = total / distinct
    ceiling = 1 - 1 / factor

    print(f"total requests : {total}")
    print(f"num runs       : {len(runs)}  lens={sorted(set(len(r) for r in runs))}")
    print(f"distinct/run Σ : {distinct}")
    print(f"batch reuse    : {factor:.3f}")
    print(f"ceiling hit    : {100*ceiling:.2f}%")
    print(f"measured LRU   : 36.24% (upstream docs/data/expert-cache-capacity.txt)")
    print(f"Belady @64GB   : 61.74% => gap {61.74-36.24:.2f}pt from cross-run reuse")


if __name__ == "__main__":
    main()
