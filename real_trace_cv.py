#!/usr/bin/env python3
"""
real_trace_cv.py — 真机 Kimi-K3 trace（kimi-k3-in-c expert_trace.bin）的
负载均匀度(CV) 与缓存命中对照。纯标准库，无 numpy 依赖。

输入：int32 对 (layer, expert) 的二进制 trace
  - layer  ∈ [0,92)
  - expert ∈ [0,896)
  - key = layer<<20 | expert

输出：
  - 全局/每层 专家访问 CV（负载均衡度量的核心）
  - CV 与本地合成 trace(RTL/03_cache/k3_trace.txt) 对比
  - LRU / Belady / Pinned 命中率曲线（对照 sim_cache.py 规格）
"""
import struct, sys, statistics
from collections import OrderedDict, Counter

def load(path):
    with open(path, 'rb') as f:
        raw = f.read()
    n = len(raw) // 4
    tr = []
    for i in range(0, n * 4, 4):
        v = struct.unpack('<i', raw[i:i+4])[0]  # int32 LE
        tr.append(v)
    # 成对 (layer, expert)
    keys = []
    for i in range(0, len(tr) - 1, 2):
        k = (tr[i] << 20) | tr[i+1]
        keys.append(k)
    return keys

def lru(trace, cap):
    seen = OrderedDict(); hits = 0
    for k in trace:
        if k in seen:
            seen.move_to_end(k); hits += 1
        else:
            if len(seen) >= cap: seen.popitem(last=False)
            seen[k] = 1
    return hits

def belady(trace, cap):
    n = len(trace)
    nxt = [n]*n; last = {}
    for i in range(n-1, -1, -1):
        k = trace[i]; nxt[i] = last.get(k, n); last[k] = i
    res = {}; hits = 0
    for i, k in enumerate(trace):
        if k in res:
            hits += 1; res[k] = nxt[i]; continue
        if len(res) >= cap:
            v = max(res, key=res.get)
            if res[v] < nxt[i]: continue
            del res[v]
        res[k] = nxt[i]
    return hits

def pinned_lru(trace, cap, npin):
    if npin >= cap: npin = cap - 1
    hot = {k for k,_ in Counter(trace).most_common(npin)}
    loaded = set(); seen = OrderedDict()
    room = max(cap-len(hot), 1); hits = 0
    for k in trace:
        if k in hot:
            if k in loaded: hits += 1
            else: loaded.add(k)
            continue
        if k in seen:
            seen.move_to_end(k); hits += 1
        else:
            if len(seen) >= room: seen.popitem(last=False)
            seen[k]=1
    return hits

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'expert_trace.bin'
    trace = load(path)
    n = len(trace)
    uniq = len(set(trace))
    c = Counter(trace)
    print(f"真机 trace: requests={n}  distinct={uniq} ({100*uniq/(92*896):.2f}% 池)")

    # ============ 负载均匀度 CV ============
    # 全局：每个专家在 trace 里被访问计数
    vals = list(c.values())
    gmean = statistics.mean(vals); gsd = statistics.pstdev(vals)
    gcv = gsd/gmean
    print(f"全局专家访问: 均={gmean:.3f} std={gsd:.3f} CV={gcv:.3f}")
    # 每层：层内专家访问分布（负载均衡的目标空间）
    bylay = {}
    for k, cnt in c.items():
        bylay.setdefault(k >> 20, []).append(cnt)
    cvs = []
    for lay, cs in bylay.items():
        m = statistics.mean(cs); s = statistics.pstdev(cs)
        cvs.append(s/m if m else 0.0)
    print(f"per-layer CV: 层数={len(cvs)} 均={statistics.mean(cvs):.3f} "
          f"中位={statistics.median(cvs):.3f} 最大={max(cvs):.3f}")

    # 对比本地合成 trace
    try:
        sync = [int(l) for l in open('/data/data/com.termux/files/home/sram/rtl/03_cache/k3_trace.txt')]
        sv = list(Counter(sync).values())
        scv = statistics.pstdev(sv)/statistics.mean(sv)
        print(f"[对照] 本地合成 trace: CV={scv:.3f}")
    except OSError:
        print("[对照] 无本地合成 trace")

    # ============ 命中率曲线 ============
    EXPERT_BYTES = 17_547_264
    caps_gb = [8,16,32,64,128,192,256,384,512,768,1024]
    print(f"\n{'GB':>5} {'SLOTS':>8} {'LRU':>8} {'BELADY':>8} {'PIN+LRU':>9}")
    for gb in caps_gb:
        cap = int(gb*1e9//EXPERT_BYTES)
        if cap < 17: continue
        h = lru(trace, cap); b = belady(trace, cap); p = pinned_lru(trace, cap, cap//2)
        print(f"{gb:>5} {cap:>8} {100*h/n:7.2f}% {100*b/n:7.2f}% {100*p/n:8.2f}%")
    comp = uniq
    print(f"\ncompulsory misses: {uniq} → 任何策略命中上限 {100*(n-uniq)/n:.2f}%")

if __name__ == '__main__':
    main()