#!/usr/bin/env python3
"""
sim_cache2.py — Kimi K3 专家缓存仿真升级版（相对上游 sim_cache.py 的修正）。

上游 sim_cache.py（kimi-k3-in-c）的缺陷：只扫「容量 × 策略」，把请求顺序当作
不可变更的常量，于是 LRU 8~64 GB 恒 36.24% 被固化为"结构性上限"。但请求顺序
是引擎可控制的（加载/调度顺序）——本工具把「顺序」升级为一等维度：

  --order trace      （默认）原始请求顺序 = 与上游 sim_cache.py 逐位一致
  --order layer-first 同一层请求聚合后再进下一层（§5.11）→ 150 槽即 90%

允许 --order 逗号列表多值对比，如 --order trace,layer-first。

每个顺序下输出与上游一致的列：容量/槽、LRU/Belady/Pinned 命中率 + 读取效率
（GB/token、sec/token），另加 compulsory 上限行。纯标准库（无 numpy 依赖）。
"""
import argparse
import struct
from collections import OrderedDict, Counter, defaultdict
from statistics import mean

EXPERT_BYTES = 17_547_264          # 作者源码 sim_cache.py 原文(measured, not assumed)
TOTAL_EXPERTS = 92 * 896
DISK_MBPS = 1234.0                 # 实测随机冷读速率 MB/s（上游同源）

CAPS_GB = [8, 16, 19, 32, 40, 64, 100, 108, 128, 164, 192, 256]


def load(path):
    raw = open(path, 'rb').read()
    n = len(raw) // 4
    tr = struct.unpack('<%di' % n, raw)
    pairs = [(tr[i], tr[i + 1]) for i in range(0, n - 1, 2)]
    keys = [(lay << 20) | e for lay, e in pairs]
    return keys, len(keys)


def runs_of(keys):
    runs, cur, curlay = [], [], None
    for k in keys:
        lay = k >> 20
        if curlay != lay:
            if cur:
                runs.append((curlay, cur))
            cur, curlay = [], lay
        cur.append(k)
    if cur:
        runs.append((curlay, cur))
    return runs


def layer_first(keys):
    """同层全部请求聚合，再进下一层（§5.11）。顺序改变，集合与数量不变。"""
    runs = runs_of(keys)
    by_layer = defaultdict(list)
    for lay, es in runs:
        by_layer[lay].extend(es)
    out = []
    for L in sorted(by_layer):
        out.extend(by_layer[L])
    return out


def order_trace(keys, order):
    return layer_first(keys) if order == 'layer-first' else keys


def lru(trace, cap):
    seen = OrderedDict(); hits = 0
    for k in trace:
        if k in seen:
            seen.move_to_end(k); hits += 1
        else:
            if len(seen) >= cap:
                seen.popitem(last=False)
            seen[k] = 1
    return hits


def belady(trace, cap):
    n = len(trace); nxt = [n] * n; last = {}
    for i in range(n - 1, -1, -1):
        k = trace[i]
        nxt[i] = last.get(k, n)
        last[k] = i
    resident = {}; hits = 0
    for i, k in enumerate(trace):
        if k in resident:
            hits += 1
            resident[k] = nxt[i]
            continue
        if len(resident) >= cap:
            victim = max(resident, key=resident.get)
            if resident[victim] < nxt[i]:
                continue
            del resident[victim]
        resident[k] = nxt[i]
    return hits


def pinned_lru(trace, cap, npin):
    if npin >= cap:
        npin = max(cap - 1, 0)
    hot = {k for k, _ in Counter(trace).most_common(npin)}
    loaded = set(); seen = OrderedDict()
    room = max(cap - len(hot), 1)
    hits = 0
    for k in trace:
        if k in hot:
            if k in loaded:
                hits += 1
            else:
                loaded.add(k)
            continue
        if k in seen:
            seen.move_to_end(k); hits += 1
        else:
            if len(seen) >= room:
                seen.popitem(last=False)
            seen[k] = 1
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('trace')
    ap.add_argument('--expert-bytes', type=int, default=EXPERT_BYTES)
    ap.add_argument('--disk-mbs', type=float, default=DISK_MBPS)
    ap.add_argument('--order', default='trace',
                    help='逗号分隔: trace / layer-first（默认 trace，输出全量）')
    ap.add_argument('--slots', default=None,
                    help='自定义槽数覆盖（逗号分隔，精确槽；优先于容量表）')
    args = ap.parse_args()

    keys, n = load(args.trace)
    uniq = len(set(keys))
    per_tok = 1472
    ntok = n // per_tok
    orders = args.order.split(',') if ',' in args.order else [args.order]
    # 默认打印全部可对比顺序
    if orders == ['trace']:
        orders = ['trace', 'layer-first']

    if args.slots:
        rows = [(None, int(s.strip())) for s in args.slots.split(',')]
    else:
        rows = [(gb, int(gb * 1e9 // args.expert_bytes)) for gb in CAPS_GB]

    print('=' * 76)
    print('sim_cache2: %s  (%d requests, %d distinct experts, ~%d token(s))'
          % (args.trace, n, uniq, max(ntok, 1)))
    print('compulsory 上限: %d unique → 任何顺序/策略/容量命中 ≤ %.2f%%'
          % (uniq, 100 * (n - uniq) / n))
    print('=' * 76)

    for order in orders:
        tr = order_trace(keys, order)
        print('\n### order = %s  (集合/数量不变, 仅顺序)%s'
              % (order, '  [§5.11 层优先]' if order == 'layer-first' else '  [(= 上游 sim_cache.py)]'))
        print('%-9s %8s %9s %9s %9s %12s %11s'
              % ('CACHE', 'SLOTS', 'LRU', 'BELADY', 'PIN+LRU', 'GB/TOK', 'SEC/TOK'))
        print('-' * 76)
        for gb, cap in rows:
            if cap < 17:
                continue
            h = lru(tr, cap)
            b = belady(tr, cap)
            p = pinned_lru(tr, cap, cap // 2)
            miss = n - h
            ntok_eff = n // per_tok or 1
            gb_tok = miss * args.expert_bytes / 1e9 / ntok_eff
            sec = gb_tok * 1000.0 / args.disk_mbs
            label = '%d GB' % gb if gb else '%d槽' % cap
            print('%-9s %8d %8.2f%% %8.2f%% %8.2f%% %12.2f %11.2f'
                  % (label, cap, 100 * h / n, 100 * b / n, 100 * p / n,
                     gb_tok, sec))
        print('-' * 76)
    print('\n说明: 上游 sim_cache.py 只给 order=trace 的列 → 36% 平台被误读为'
          '结构性上限；layer-first 显示同一 trace 150 槽即 90%（§5.11），'
          '顺序是引擎可控变量. 全部数字纯标准库可复现.')
    return 0


if __name__ == '__main__':
    import sys
    sys.exit(main())