#!/usr/bin/env python3
"""D 档双缓冲时序仿真器.

与 profile_trace.py 互补：profile_trace 只回答“容量下的命中率/字节量”，
这里在**相同容量模型**上对比 B（同步 LRU）与 D（超前预取）的 I/O 时序，
从而量化“预取能否被计算隐藏”，并给出所需最小超前量。

模型约定
--------
- 读模型：聚合带宽 —— 一批 count 个专家 = r0 延迟 + count*bytes/BW。
  D 档每 token 预取整批（跨 60 层合并提交，只付一次 r0）；B 档按层调用同步付
  （符合 SparkMoE resolve() 现状，每层各自等待）。
- 容量：B/D 用**同一组** per-layer LRU 槽位（budget/n_layers/bpe），因此两者
  读入字节数相同，本仿真只揭示“读得更早”带来的吞吐差。
- 预取内容落池即视为可命中；容量抖动（提前逐出→二次读）计入 sync 读。
- 未建模：池容量上限外的 pinned 热表（那是 profile_trace 的档位表）、多设备并行。

输出：compute-bound / B / D 各 lookahead 的 tok/s、被隐藏读占比、最小超前量公式。
"""
import argparse
import importlib.util
import json
import math
import sys
from collections import OrderedDict
from pathlib import Path

HERE = Path(__file__).resolve().parent
GIB = 1 << 30


def load_pt():
    spec = importlib.util.spec_from_file_location("pt", HERE / "profile_trace.py")
    pt = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pt)
    return pt


class ReadModel:
    def __init__(self, r0_ms, bw_mib_s, bytes_per_expert):
        self.r0 = r0_ms
        self.bw = bw_mib_s / 1000.0  # MiB per ms
        self.bytes = bytes_per_expert

    def batch_latency(self, count):
        if count <= 0:
            return 0.0
        return self.r0 + count * self.bytes / (1 << 20) / self.bw


class Link:
    """单链路带宽队列：所有读批按提交时间串行，完成时间 = max(提交, 链路空闲) + r0 + 字节/BW。"""

    def __init__(self, rm):
        self.rm = rm
        self.free_at = 0.0

    def issue(self, count, at):
        """提交 count 个专家的读批，返回该批的完成时间。"""
        if count <= 0:
            return at
        start = max(at, self.free_at)
        done = start + self.rm.batch_latency(count)
        self.free_at = done
        return done

    def per_layer_completion(self, fresh_by_layer, order_layers, at):
        """跨层合并为一批提交；返回 {layer: 完成时间}（按层序累计占用带宽）。"""
        total = sum(len(v) for v in fresh_by_layer.values())
        if total <= 0:
            return {}
        start = max(at, self.free_at)
        head = start + self.rm.r0
        duration = total * self.rm.bytes / (1 << 20) / self.rm.bw
        self.free_at = head + duration
        acc = 0
        out = {}
        for layer in order_layers:
            c = len(fresh_by_layer.get(layer, ()))
            if c:
                acc += c
                out[layer] = head + acc * self.rm.bytes / (1 << 20) / self.rm.bw
        return out


def make_slots(budget_gib, layers, pt, bpe):
    return {
        layer: max(1, int(budget_gib * GIB // (len(layers) * pt.bpe_of(bpe, layer))))
        for layer in layers
    }


class LRU:
    __slots__ = ("cap", "cache")

    def __init__(self, cap):
        self.cap = cap
        self.cache = OrderedDict()

    def probe(self, e):
        return e in self.cache

    def touch(self, e):
        self.cache.move_to_end(e)

    def insert(self, e):
        self.cache[e] = None
        while len(self.cache) > self.cap:
            self.cache.popitem(last=False)


def simulate_sync_lru(order, per_layer, slots, compute_per_layer, rm):
    """B 档：每层调用时缺则同步读（付 r0+字节/BW），无预取。"""
    caches = {}
    link = Link(rm)
    t = 0.0
    reads = 0
    for token in order:
        for layer, experts in per_layer[token].items():
            cache = caches.get(layer)
            if cache is None:
                cache = LRU(slots.get(layer, 1))
                caches[layer] = cache
            miss = 0
            for e in set(experts):
                if cache.probe(e):
                    cache.touch(e)
                else:
                    miss += 1
                    cache.insert(e)
            t += compute_per_layer
            if miss:
                t = max(t, link.issue(miss, t))
                reads += miss
    return t, reads


def simulate_prefetch(order, per_layer, slots, lookahead, pred_fn, compute_per_layer, rm):
    """D 档：token i 末尾提交 token i+lookahead 的预取（跨层合并一批、一次 r0），
    FIFO 共享链路与执行期同步补读公平排队。执行时缺（预测错/被逐出）则同步补读。
    返回 (总时间, 预取字节, sync 读字节, 等待ms)。"""
    caches = {}
    link = Link(rm)
    ready = {}
    t = 0.0
    prefetch_bytes = 0.0
    sync_bytes = 0.0
    wait_ms = 0.0
    n = len(order)
    for i in range(n):
        for layer, experts in per_layer[order[i]].items():
            cache = caches.get(layer)
            if cache is None:
                cache = LRU(slots.get(layer, 1))
                caches[layer] = cache
            r = ready.pop((i, layer), None)
            if r is not None and r > t:
                wait_ms += r - t
                t = r
            need = set(experts)
            for e in need:
                if cache.probe(e):
                    cache.touch(e)
            miss = [e for e in need if not cache.probe(e)]
            if miss:
                sync_bytes += len(miss) * rm.bytes
                t = max(t, link.issue(len(miss), t))
                for e in miss:
                    cache.insert(e)
            t += compute_per_layer
        if i + lookahead < n:
            tk = order[i + lookahead]
            fresh_by_layer = {}
            for layer in sorted(per_layer[order[i]].keys()):
                cache = caches.get(layer)
                if cache is None:
                    cache = LRU(slots.get(layer, 1))
                    caches[layer] = cache
                pred = pred_fn(tk, layer)
                fresh = [e for e in pred if not cache.probe(e)]
                fresh_by_layer[layer] = fresh
                for e in fresh:
                    cache.insert(e)
            completions = link.per_layer_completion(fresh_by_layer, sorted(per_layer[order[i]].keys()), t)
            for layer, done in completions.items():
                ready[(tk, layer)] = done
            total_fresh = sum(len(v) for v in fresh_by_layer.values())
            prefetch_bytes += total_fresh * rm.bytes
    return t, prefetch_bytes, sync_bytes, wait_ms


def make_oracle_pred(order, per_layer):
    def pred(tk, layer):
        return per_layer[tk].get(layer, ())
    return pred


def make_markov_pred(transitions, per_layer):
    def pred(tk, layer):
        t = transitions.get(str(layer), transitions.get(layer))
        if not t:
            return ()
        nxt = set()
        for e in per_layer[tk].get(layer, ()):
            row = t.get(str(e), t.get(e))
            if row:
                nxt.add(row[0]["next"])
        return sorted(nxt)
    return pred


def per_token(t, n):
    return n * 1000.0 / t if t > 0 else float("inf")


def run_case(args, order, per_layer, layers, bpe, transitions):
    rm = ReadModel(args.latency_ms, args.bandwidth_mib_s, pt.bpe_of(bpe, layers[0]))
    slots = make_slots(args.budget_gib, layers, pt, bpe)
    compute_per_layer = args.compute_ms / len(layers)
    compute_bound = per_token(args.compute_ms, 1)

    lines = []
    lines.append(f"== 参数 == budget {args.budget_gib} GiB | slots/层 {slots[layers[0]]} "
                 f"| bytes/专家 {rm.bytes / (1 << 20):.2f} MiB | compute {args.compute_ms} ms/token "
                 f"| r0 {args.r0_ms if args.r0_ms else args.latency_ms} ms | BW {args.bandwidth_mib_s} MiB/s")
    lines.append(f"compute-bound tok/s: {compute_bound:.1f}")
    n_tok = len(order)
    t_b, reads_b = simulate_sync_lru(order, per_layer, slots, compute_per_layer, rm)
    lines.append(f"B 同步 LRU  : {per_token(t_b, n_tok):11.4g} tok/s | {t_b:9.1f} ms | 读 {reads_b} 专家 "
                 f"({reads_b * rm.bytes / (1 << 20):.1f} MiB)")

    for mode, fn in (("oracle", make_oracle_pred(order, per_layer)),):
        for k in args.lookahead:
            t_d, pf, sync, wait = simulate_prefetch(order, per_layer, slots, k, fn, compute_per_layer, rm)
            pf_mib = pf / (1 << 20)
            sync_mib = sync / (1 << 20)
            lines.append(
                f"D {mode:6s} k={k} : {per_token(t_d, n_tok):11.4g} tok/s | {t_d:9.1f} ms | "
                f"预取 {pf_mib:.1f} MiB | sync 补读 {sync_mib:.1f} MiB | 等待 {wait:.1f} ms"
            )
    if transitions and args.markov:
        for k in args.lookahead:
            fn = make_markov_pred(transitions, per_layer)
            t_d, pf, sync, wait = simulate_prefetch(order, per_layer, slots, k, fn, compute_per_layer, rm)
            lines.append(
                f"D markov k={k} : {per_token(t_d, n_tok):11.4g} tok/s | {t_d:9.1f} ms | "
                f"预取 {pf / (1 << 20):.1f} MiB | sync 补读 {sync / (1 << 20):.1f} MiB | 等待 {wait:.1f} ms"
            )

    # 最小超前量公式：以 oracle k=1 的预取字节/token 为稳定态读量
    t_o1, pf_o1, _, _ = simulate_prefetch(order, per_layer, slots, 1, make_oracle_pred(order, per_layer),
                                          compute_per_layer, rm)
    bytes_token = pf_o1 / len(order) / (1 << 20)  # MiB/token
    io_per_token = args.r0_ms + bytes_token / (args.bandwidth_mib_s / 1000.0)
    k_min = max(1, math.ceil(io_per_token / args.compute_ms))
    lines.append("")
    lines.append("== 最小超前量 ==")
    lines.append(f"稳定态读 {bytes_token:.2f} MiB/token → I/O {io_per_token:.1f} ms/token "
                 f"(r0 {args.r0_ms} ms + 传输)")
    lines.append(f"compute {args.compute_ms} ms/token → 需 k ≥ {k_min}（k 即预取提前的 token 数）")
    if k_min <= 1:
        lines.append("结论：单步预取即可完全隐藏读延迟（I/O ≤ compute）。")
    elif k_min <= args.lookahead[-1]:
        lines.append(f"结论：需两级预取；当前设置下 k={args.lookahead[-1]} 足够。")
    else:
        lines.append(f"结论：I/O 超过 compute 且可用的最大 lookahead（k={args.lookahead[-1]}）无法完全隐藏。")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser(description="MoE 专家双缓冲时序仿真")
    ap.add_argument("--trace", help="路由 trace JSONL（同 profile_trace.py 格式）")
    ap.add_argument("--manifest", help="bytes_per_expert 清单 JSON")
    ap.add_argument("--transitions", help="transitions.json（markov 预测器用）")
    ap.add_argument("--budget-gib", type=float, required=True, help="专家池预算 GiB（= 档位预算）")
    ap.add_argument("--compute-ms", type=float, default=2.0, help="每 token 纯计算时间 ms")
    ap.add_argument("--latency-ms", type=float, default=5.0, help="每批读 r0 延迟 ms")
    ap.add_argument("--r0-ms", type=float, default=None, help="r0（默认=--latency-ms）")
    ap.add_argument("--bandwidth-mib-s", type=float, default=2048.0, help="专家读聚合带宽 MiB/s")
    ap.add_argument("--lookahead", default="1,2,4", help="预取提前量 token 列表")
    ap.add_argument("--markov", action="store_true", help="附带 markov 预测器仿真")
    args = ap.parse_args()

    global pt
    pt = load_pt()
    if args.r0_ms is None:
        args.r0_ms = args.latency_ms
    bpe = {}
    if args.manifest:
        with open(args.manifest, "r", encoding="utf-8") as fh:
            bpe = json.load(fh).get("bytes_per_expert", {})
    order, per_layer = pt.group_by_token(pt.parse_records(args.trace), None)
    layers = sorted({l for tok in order for l in per_layer[tok]})
    transitions = None
    if args.transitions:
        with open(args.transitions, "r", encoding="utf-8") as fh:
            transitions = json.load(fh)
    args.lookahead = [int(x) for x in args.lookahead.split(",")]
    run_case(args, order, per_layer, layers, bpe, transitions)


if __name__ == "__main__":
    main()
