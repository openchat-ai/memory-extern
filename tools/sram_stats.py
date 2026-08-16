#!/usr/bin/env python3
"""
sram_stats.py - real-trace statistics for the L0 SRAM tier decision rule.

Reads a kimi-k3 --dump-cache-trace fixture (int32 (layer, expert) pairs).
The dump is BATCHED and LAYER-MAJOR: it is a sequence of runs, each run is
one (super-iteration, layer) group holding T tokens x 16 routed experts of
that layer. Replay order is the real request order the engine's cache saw.

K3 routed experts are PER-LAYER distinct weights (896/layer, 92 layers), so a
numeric expert id means different weights in different layers. A global SRAM
pool can only retain (layer, expert) keys across runs.

Outputs the SRAM decision-rule inputs:
  O           how much per-layer hot sets overlap across layers (disjoint -> 0)
  global n50  hottest keys covering 50% of all requests
  SRAM sizes  static top-K coverage vs global LRU at 50/100/200/400 MB
  batch reuse intra-run (same batch, same layer) vs inter-run reuse
"""
from __future__ import annotations

import argparse
import statistics
import struct
from collections import Counter, OrderedDict

EXPERT_BYTES = 17_547_264          # measured, from tests/fixtures README
N_EXPERTS = 896                    # routed experts per layer


def load_trace(path: str):
    raw = open(path, "rb").read()
    if len(raw) % 4:
        raise SystemExit("trace is not an even number of int32")
    n = len(raw) // 8
    layers = [0] * n
    experts = [0] * n
    for i in range(n):
        layers[i], experts[i] = struct.unpack_from("<ii", raw, i * 8)
    return layers, experts


def runs_of(layers):
    runs = []
    start = 0
    for i in range(1, len(layers) + 1):
        if i == len(layers) or layers[i] != layers[start]:
            runs.append((layers[start], start, i))
            start = i
    return runs


def cum_cover(counter: Counter, k: int) -> float:
    total = sum(counter.values())
    return 100.0 * sum(v for _, v in counter.most_common(k)) / total


def n_at_cover(counter: Counter, pct: float) -> int:
    target = pct / 100.0 * sum(counter.values())
    s = 0
    for i, (_, v) in enumerate(counter.most_common(), 1):
        s += v
        if s >= target:
            return i
    return len(counter)


def lru_hits(keys, cap: int) -> int:
    seen = OrderedDict()
    hits = 0
    for k in keys:
        if k in seen:
            seen.move_to_end(k)
            hits += 1
        else:
            if len(seen) >= cap:
                seen.popitem(last=False)
            seen[k] = None
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--expert-bytes", type=int, default=EXPERT_BYTES)
    a = ap.parse_args()

    layers, experts = load_trace(a.trace)
    keys = [l * N_EXPERTS + e for l, e in zip(layers, experts)]
    n = len(keys)
    eb = a.expert_bytes
    runs = runs_of(layers)
    nlayers = len(set(layers))

    c = Counter(keys)
    uniq = len(c)
    print(f"trace: {n} requests, {len(runs)} runs, {nlayers} layers, "
          f"run len {min(r[2]-r[1] for r in runs)}..{max(r[2]-r[1] for r in runs)}")
    print(f"distinct (layer,expert): {uniq} of {nlayers*N_EXPERTS} pool "
          f"({100.0*uniq/(nlayers*N_EXPERTS):.2f}%)")
    print()

    # --- global coverage (layer-qualified keys) ---
    n50 = n_at_cover(c, 50)
    n80 = n_at_cover(c, 80)
    print("== GLOBAL top-K over (layer,expert) keys ==")
    print(f"  n50 = {n50} keys = {n50*eb/1e9:.2f} GB   "
          f"n80 = {n80} keys = {n80*eb/1e9:.2f} GB")
    for mb in (50, 100, 200, 400, 800):
        slots = mb * 1024 * 1024 // eb
        print(f"  SRAM {mb:4d} MB -> {slots:3d} slots: static top-K "
              f"{cum_cover(c, slots):6.2f}%   LRU {100.0*lru_hits(keys, slots)/n:6.2f}%")
    print()

    # --- O: per-layer hot sets across layers ---
    per_layer = Counter(layers)
    n50s = []
    for l in per_layer:
        cnt = Counter(e for ll, e in zip(layers, experts) if ll == l)
        n50s.append(n_at_cover(cnt, 50))
    mean_n50 = statistics.mean(n50s)
    print("== O (cross-layer hot-set overlap) ==")
    print(f"  mean per-layer n50 = {mean_n50:.1f} experts "
          f"-> {mean_n50*eb/1e9:.2f} GB if per-layer")
    print(f"  global n50 = {n50} keys ({n50*eb/1e9:.2f} GB); "
          f"92 x per-layer n50 = {92*mean_n50:.0f} keys")
    print(f"  ratio global n50 / (92 x per-layer n50) = "
          f"{n50/(92*mean_n50):.3f}  (1.0 = disjoint hot sets, O=0)")
    print()

    # --- batch reuse structure ---
    intra = inter = 0
    run_seen = set()
    global_seen = set()
    batch = []                       # (run distinct, run length)
    for _, st, en in runs:
        run_keys = keys[st:en]
        run_set = set(run_keys)
        batch.append((len(run_set), len(run_keys)))
        for k in run_keys:
            if k in run_seen:
                intra += 1
            if k in global_seen:
                inter += 1
            global_seen.add(k)
        run_seen |= run_set
    print("== batch reuse (O at run granularity) ==")
    print(f"  intra-run repeats:  {intra} ({100.0*intra/n:.2f}%)  "
          f"(same layer batch, T tokens share experts)")
    print(f"  inter-run repeats:  {inter} ({100.0*inter/n:.2f}%)")
    print(f"  compulsory distinct:{n-inter} ({100.0*(n-inter)/n:.2f}%)")
    dr, rl = zip(*batch)
    print(f"  per-run: mean {statistics.mean(dr):.1f} distinct experts "
          f"for {statistics.mean(rl):.1f} requests "
          f"(batch reuse factor {statistics.mean(rl)/statistics.mean(dr):.2f}x)")
    print()

    # --- per-layer top-16 stability, first vs second half of requests ---
    stab = []
    for l in per_layer:
        reqs = [e for ll, e in zip(layers, experts) if ll == l]
        half = len(reqs) // 2
        cnt_a = Counter(reqs[:half])
        cnt_b = Counter(reqs[half:])
        top_a = set(k for k, _ in cnt_a.most_common(16))
        top_b = set(k for k, _ in cnt_b.most_common(16))
        stab.append(len(top_a & top_b) / 16.0)
    print("== per-layer top-16 stability, first vs second half of requests ==")
    print(f"  mean overlap {100.0*statistics.mean(stab):.1f}%  "
          f"median {100.0*sorted(stab)[len(stab)//2]:.1f}%")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
