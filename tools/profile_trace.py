#!/usr/bin/env python3
import argparse
import json
import math
import sys
from collections import OrderedDict, defaultdict
from pathlib import Path

GIB = 1 << 30
FIELD_ALIASES = {
    "layer": ("layer", "l", "layer_id", "il", "lay"),
    "experts": ("experts", "exp", "expert_ids", "ids", "routed", "selected_experts", "e"),
    "token": ("token", "tok", "token_id", "t"),
}


def resolve_key_map(record):
    keymap = {}
    for canonical, aliases in FIELD_ALIASES.items():
        keymap[canonical] = next(
            (key for key in record if str(key).lower() in aliases), None
        )
    return keymap


def parse_records(path):
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                yield json.loads(line)


def iter_layer_calls(records, max_tokens):
    keymap = None
    has_token = False
    token = 0
    last_layer = -1
    for record in records:
        if keymap is None:
            keymap = resolve_key_map(record)
            if keymap["layer"] is None or keymap["experts"] is None:
                sys.exit("trace records need a 'layer' and an 'experts' field; see --help")
            has_token = keymap["token"] is not None
        layer = record[keymap["layer"]]
        experts = record[keymap["experts"]]
        if has_token:
            token = record[keymap["token"]]
        elif layer < last_layer:
            token += 1
        last_layer = layer
        if experts is None:
            experts = []
        elif not isinstance(experts, (list, tuple)):
            experts = [experts]
        if max_tokens is not None and token >= max_tokens:
            continue
        yield token, int(layer), [int(e) for e in experts]


def group_by_token(records, max_tokens):
    per_layer = {}
    order = []
    for token, layer, experts in iter_layer_calls(records, max_tokens):
        bucket = per_layer.get(token)
        if bucket is None:
            bucket = {}
            per_layer[token] = bucket
            order.append(token)
        bucket[layer] = experts
    return order, per_layer


def powerlaw_weights(n, alpha):
    return [1.0 / (rank + 1.0) ** alpha for rank in range(n)]


def weighted_sample_no_replacement(population, weights, k, rng):
    result = []
    available = list(range(len(population)))
    for _ in range(min(k, len(available))):
        total = sum(weights[i] for i in available)
        r = rng.random() * total
        acc = 0.0
        pick = available[-1]
        for i in available:
            acc += weights[i]
            if acc >= r:
                pick = i
                break
        result.append(population[pick])
        available.remove(pick)
    return result


def generate_demo(seed, n_layers, n_experts, n_tokens, topk, alpha, stay_p, stay_k, out_path):
    import random

    rng = random.Random(seed)
    all_weights = powerlaw_weights(n_experts, alpha)
    pool = list(range(n_experts))
    cur = []
    with open(out_path, "w", encoding="utf-8") as fh:
        for token in range(n_tokens):
            if token == 0:
                cur = weighted_sample_no_replacement(pool, all_weights, topk, rng)
            elif rng.random() < stay_p:
                keep = cur[:stay_k]
                avail = [e for e in pool if e not in keep]
                wavail = [all_weights[e] for e in avail]
                cur = keep + weighted_sample_no_replacement(avail, wavail, topk - stay_k, rng)
            else:
                cur = weighted_sample_no_replacement(pool, all_weights, topk, rng)
            for layer in range(n_layers):
                experts = [(e + layer) % n_experts for e in cur]
                fh.write(json.dumps({"token": token, "layer": layer, "experts": experts}) + "\n")


def collect_stats(order, per_layer):
    calls = defaultdict(int)
    freq = defaultdict(lambda: defaultdict(int))
    trans_flat = defaultdict(int)
    overlap_sum = 0.0
    overlap_count = 0
    for ti, token in enumerate(order):
        if ti == 0:
            continue
        prev = per_layer[order[ti - 1]]
        cur = per_layer[token]
        for layer, experts in cur.items():
            unique = list(set(experts))
            calls[layer] += 1
            for e in unique:
                freq[layer][e] += 1
            prev_set = set(prev.get(layer, ()))
            if not prev_set:
                continue
            hits = sum(1 for e in unique if e in prev_set)
            overlap_sum += hits / len(unique)
            overlap_count += 1
            for e in prev_set:
                for f in unique:
                    trans_flat[(layer, e, f)] += 1
    return calls, freq, trans_flat, overlap_sum, overlap_count


def build_hot_lists(freq, calls):
    result = {}
    for layer, counts in freq.items():
        ranked = sorted(counts.items(), key=lambda kv: -kv[1])
        total = sum(counts.values())
        cum = 0.0
        coverage = []
        for e, c in ranked:
            cum += c / total
            coverage.append((e, cum))
        n50 = next((i + 1 for i, (_, cov) in enumerate(coverage) if cov >= 0.5), len(ranked))
        top20 = math.ceil(len(ranked) * 0.20) or 1
        cov_top20 = coverage[top20 - 1][1] if coverage else 0.0
        result[layer] = {
            "total_calls": calls[layer],
            "n_experts_seen": len(ranked),
            "n50": n50,
            "top20pct_coverage": round(cov_top20, 4),
            "top": [e for e, _ in coverage[: max(8, n50)]],
        }
    return result


def build_transitions(trans_flat):
    grouped = defaultdict(lambda: defaultdict(lambda: defaultdict(int)))
    for (layer, cur, nxt), count in trans_flat.items():
        grouped[layer][cur][nxt] += count
    result = {}
    for layer, per_cur in grouped.items():
        layer_out = {}
        peak_hit = 0.0
        n_cur = 0
        for cur, per_next in per_cur.items():
            total_next = sum(per_next.values())
            if total_next == 0:
                continue
            ranked = sorted(per_next.items(), key=lambda kv: -kv[1])
            top = [{"next": n, "p": round(c / total_next, 4)} for n, c in ranked[:8]]
            layer_out[str(cur)] = top
            peak_hit += ranked[0][1] / total_next
            n_cur += 1
        layer_out["_peak_hit"] = round(peak_hit / max(1, n_cur), 4)
        result[layer] = layer_out
    return result


def entropy_of(freq):
    total = sum(freq.values())
    return -sum((c / total) * math.log2(c / total) for c in freq.values() if c > 0)


def coverage_for_static(ranked, slots):
    return sum(c for _, c in ranked[:slots]) / sum(c for _, c in ranked) if ranked else 0.0


def simulate_static_uniform(budget_bytes, freq, bytes_per_expert):
    layers = sorted(freq.keys())
    return {
        layer: coverage_for_static(
            sorted(freq[layer].items(), key=lambda kv: -kv[1]),
            max(1, int(budget_bytes // (len(layers) * bpe_of(bytes_per_expert, layer)))),
        )
        for layer in layers
    }


def bpe_of(bytes_per_expert, layer):
    value = bytes_per_expert.get(str(layer), bytes_per_expert.get(layer, 1))
    return value if value else 1


def simulate_static_global(budget_bytes, freq, bytes_per_expert):
    covered, _, _ = global_greedy(budget_bytes, freq, bytes_per_expert)
    return covered


def simulate_lru_multi(layer_slots_list, order, per_layer):
    n = len(layer_slots_list)
    caches = [None] * n
    misses = [0] * n
    touches = [0] * n
    miss_by_layer = [defaultdict(int) for _ in range(n)]
    enabled = [{l: s for l, s in slots.items() if s > 0} for slots in layer_slots_list]
    for token in order:
        per_tok = per_layer[token]
        for layer, experts in per_tok.items():
            uniq = set(experts)
            for idx, active in enumerate(enabled):
                slots = active.get(layer, 0)
                if slots <= 0:
                    continue
                cache = caches[idx]
                if cache is None:
                    cache = {}
                    caches[idx] = cache
                c = cache.get(layer)
                if c is None:
                    c = OrderedDict()
                    cache[layer] = c
                for e in uniq:
                    touches[idx] += 1
                    if e in c:
                        c.move_to_end(e)
                    else:
                        misses[idx] += 1
                        miss_by_layer[idx][layer] += 1
                        c[e] = None
                        if len(c) > slots:
                            c.popitem(last=False)
    return misses, touches, miss_by_layer


def global_greedy(budget_bytes, freq, bpe):
    items = []
    for layer, counts in freq.items():
        b = bpe_of(bpe, layer)
        total = sum(counts.values())
        for e, c in counts.items():
            items.append((c / b, layer, e, b, c))
    items.sort(key=lambda it: -it[0])
    spent = 0
    covered_calls = 0
    total_calls = sum(it[4] for it in items)
    pinned = {}
    for _, layer, e, b, count in items:
        if spent + b > budget_bytes:
            continue
        spent += b
        covered_calls += count
        pinned.setdefault(layer, set()).add(e)
    return (covered_calls / total_calls if total_calls else 0.0), pinned, spent


def simulate_tier(order, per_layer, slots, pinned):
    misses = 0
    touches = 0
    full_hit_calls = 0
    n_calls = 0
    miss_by_layer = defaultdict(int)
    caches = {}
    for token in order:
        for layer, experts in per_layer[token].items():
            uniq = set(experts)
            n_calls += 1
            cap = slots.get(layer, 0)
            pin = pinned.get(layer, set())
            cache = caches.get(layer)
            if cache is None:
                cache = OrderedDict()
                caches[layer] = cache
            all_hit = True
            for e in uniq:
                touches += 1
                if e in pin:
                    continue
                if e in cache:
                    cache.move_to_end(e)
                else:
                    misses += 1
                    all_hit = False
                    miss_by_layer[layer] += 1
                    if cap:
                        cache[e] = None
                        if len(cache) > cap:
                            cache.popitem(last=False)
            if all_hit:
                full_hit_calls += 1
    return {
        "miss": misses / touches if touches else 0.0,
        "full_hit": full_hit_calls / n_calls if n_calls else 0.0,
        "miss_by_layer": miss_by_layer,
    }


def simulate_temporal_ceiling(order, per_layer, pinned):
    misses = 0
    touches = 0
    full_hit_calls = 0
    n_calls = 0
    miss_by_layer = defaultdict(int)
    prev_sets = {}
    for token in order:
        for layer, experts in per_layer[token].items():
            uniq = set(experts)
            n_calls += 1
            pin = pinned.get(layer, set())
            prevs = prev_sets.get(layer, set())
            all_hit = True
            for e in uniq:
                touches += 1
                if e not in pin and e not in prevs:
                    misses += 1
                    all_hit = False
                    miss_by_layer[layer] += 1
            if all_hit:
                full_hit_calls += 1
            prev_sets[layer] = uniq
    return {
        "miss": misses / touches if touches else 0.0,
        "full_hit": full_hit_calls / n_calls if n_calls else 0.0,
        "miss_by_layer": miss_by_layer,
    }


def write_report(report_path, hot_list_path, order, per_layer, calls, freq, transitions, hot,
                 budgets, tier_budget, bpe, temporal, src):
    lines = []
    lines.append("# MoE 路由 trace 分析报告")
    lines.append("")
    n_tokens = len(order)
    total_calls = sum(calls.values())
    lines.append(f"- source: {src}")
    lines.append(f"- tokens: {n_tokens}")
    lines.append(f"- layer calls: {total_calls}")
    lines.append(f"- layers: {len(calls)}")
    lines.append(f"- 时序局部性 (上一批专家在下一批中复用的比例, 一步预取上界): {temporal:.4f}")
    lines.append("")
    lines.append("## 每层偏斜度")
    lines.append("")
    lines.append("| layer | calls | unique | n50 | top20% 覆盖 | 熵(bits) | peak-1 预测命中 |")
    lines.append("|-------|-------|--------|-----|-------------|----------|-----------------|")
    for layer in sorted(calls.keys()):
        hot_l = hot.get(layer, {})
        lines.append(
            f"| {layer} | {calls[layer]} | {hot_l.get('n_experts_seen', 0)} | {hot_l.get('n50', 0)} "
            f"| {hot_l.get('top20pct_coverage', 0)} | {entropy_of(freq[layer]):.2f} "
            f"| {transitions.get(layer, {}).get('_peak_hit', 0)} |"
        )
    lines.append("")
    lines.append("## 静态银行命中率预估")
    lines.append("")
    lines.append("| 预算 (GiB) | uniform 每层静态 | global 全局贪心 | LRU 仿真 | misses/token | bytes/token |")
    lines.append("|------------|-----------------|----------------|----------|--------------|-------------|")
    layers = sorted(freq.keys())
    lru_slots = []
    lru_skip = []
    for budget in budgets:
        slots = {
            layer: max(1, int(budget * GIB // (len(layers) * bpe_of(bpe, layer))))
            for layer in layers
        }
        lru_slots.append(slots)
        lru_skip.append(
            all(slots.get(l, 0) >= hot.get(l, {}).get("n_experts_seen", 1 << 30) for l in layers)
        )
    lru_stats = simulate_lru_multi(
        [s for s, skip in zip(lru_slots, lru_skip) if not skip], order, per_layer
    )
    lru_misses_list, lru_touches_list, lru_mbl_list = lru_stats
    lru_iter = zip(lru_misses_list, lru_touches_list, lru_mbl_list)
    for budget in budgets:
        uni = simulate_static_uniform(budget * GIB, freq, bpe)
        uni_avg = sum(uni.values()) / len(uni) if uni else 0.0
        global_cov = simulate_static_global(budget * GIB, freq, bpe)
        if lru_skip[budgets.index(budget)]:
            lru_miss, lru_miss_token, lru_bytes_token = 0.0, 0.0, 0.0
        else:
            lru_miss_cnt, lru_touches, lru_mbl = next(lru_iter)
            lru_miss = lru_miss_cnt / lru_touches if lru_touches else 0.0
            lru_miss_token = lru_miss_cnt / n_tokens if n_tokens else 0.0
            lru_bytes_token = (
                sum(lru_mbl[l] * bpe_of(bpe, l) for l in lru_mbl) / n_tokens if n_tokens else 0.0
            )
        lines.append(
            f"| {budget} | {uni_avg:.4f} | {global_cov:.4f} | miss={lru_miss:.4f} (hit={1 - lru_miss:.4f}) "
            f"| {lru_miss_token:.2f} | {lru_bytes_token / (1 << 20):.2f} MiB |"
        )
    lines.append("")
    lines.append(f"## 档位上限（离线预估，预算 {tier_budget} GiB，不建模 I/O 时序）")
    lines.append("")
    lines.append("| 档位 | 专家命中率 | 满命中层率 | misses/token | bytes/token |")
    lines.append("|------|-----------|-----------|--------------|-------------|")
    S_l = {
        layer: max(1, int(tier_budget * GIB // (len(layers) * bpe_of(bpe, layer))))
        for layer in layers
    }
    _, pinned, pinned_bytes = global_greedy(tier_budget * GIB, freq, bpe)
    lru_budget = max(0, tier_budget * GIB - pinned_bytes)
    c_slots = {
        layer: max(1, int(lru_budget // (len(layers) * bpe_of(bpe, layer)))) if lru_budget else 0
        for layer in layers
    }
    tier_b = simulate_tier(order, per_layer, S_l, {})
    tier_c = simulate_tier(order, per_layer, c_slots, pinned)
    tier_d = simulate_temporal_ceiling(order, per_layer, pinned)
    pinned_avg = sum(len(p) for p in pinned.values()) / len(layers) if layers else 0.0
    lines.append("")
    lines.append(f"（静态热表 pinned 专家/层平均 {pinned_avg:.1f}，用去 {pinned_bytes / (1 << 20):.1f} MiB）")
    for label, tier in (("B 纯 LRU", tier_b), ("C 热表+LRU", tier_c), ("D 热表+时序(上界)", tier_d)):
        miss_token = sum(tier["miss_by_layer"].values()) / n_tokens if n_tokens else 0.0
        bytes_token = (
            sum(tier["miss_by_layer"][l] * bpe_of(bpe, l) for l in tier["miss_by_layer"]) / n_tokens
            if n_tokens
            else 0.0
        )
        lines.append(
            f"| {label} | {1 - tier['miss']:.4f} | {tier['full_hit']:.4f} "
            f"| {miss_token:.2f} | {bytes_token / (1 << 20):.2f} MiB |"
        )
    gain_c = (1 - tier_c["miss"]) / (1 - tier_b["miss"]) if tier_b["miss"] < 1 else float("inf")
    gain_d = (1 - tier_d["miss"]) / (1 - tier_b["miss"]) if tier_b["miss"] < 1 else float("inf")
    lines.append("")
    lines.append(f"**净收益**：C/B = {gain_c:.2f}x，D/B = {gain_d:.2f}x（D 为含时序预取的上界，假设预取时序无损）。")
    lines.append("")
    lines.append("> 决策门：若 C/B < 1.10，静态热表不值得做 C++（§4 行动 3）。")
    lines.append("")
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")

    with open(hot_list_path, "w", encoding="utf-8") as fh:
        fh.write(
            f"# L0 static pinned experts (global greedy) under {tier_budget} GiB\n"
            f"# format: <layer>: <expert_id>,...  (per-layer top-K, freq 降序)\n"
        )
        for layer in layers:
            ranked = sorted(pinned.get(layer, set()), key=lambda e: -freq[layer][e])
            fh.write(f"{layer}: {','.join(str(e) for e in ranked)}\n")


def main():
    ap = argparse.ArgumentParser(
        description="MoE 路由 trace 分析器：生成每层热表、一阶转移表、偏斜度与静态/LRU 银行命中率预估。"
    )
    ap.add_argument("--trace", help="路由 trace JSONL（每行一条 {token, layer, experts:[...]} 记录）；"
                                    "可省略 token 字段：按 layer 回绕自动切分 token（流式模式，适合 C++ 钩子直接 dump）")
    ap.add_argument("--manifest", help="可选清单 JSON：{bytes_per_expert: {layer: bytes}}")
    ap.add_argument("--demo", action="store_true", help="生成合成 trace 并跑完整流程")
    ap.add_argument("--outdir", default=".", help="输出目录（默认当前目录）")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--n-layers", type=int, default=48)
    ap.add_argument("--n-experts", type=int, default=64)
    ap.add_argument("--n-tokens", type=int, default=2000)
    ap.add_argument("--topk", type=int, default=4)
    ap.add_argument("--alpha", type=float, default=1.5, help="幂律偏斜指数（越大越偏斜）")
    ap.add_argument("--stay-p", type=float, default=0.8, help="合成负载中保持上批专家的概率")
    ap.add_argument("--stay-k", type=int, default=2, help="合成负载中保持的上批专家个数")
    ap.add_argument("--max-tokens", type=int, default=None, help="只分析前 N 个 token")
    ap.add_argument("--bank-budgets", default="4,8,16", help="命中率预估的 GiB 预算列表")
    ap.add_argument("--tier-budget-gib", type=float, default=None,
                    help="档位上限表与 hot_list.txt 的预算 GiB（默认取 bank-budgets 第一档）")
    args = ap.parse_args()

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    bpe = {}
    if args.demo:
        trace_path = outdir / "demo-trace.jsonl"
        manifest_path = outdir / "demo-manifest.json"
        generate_demo(
            args.seed, args.n_layers, args.n_experts, args.n_tokens,
            args.topk, args.alpha, args.stay_p, args.stay_k, trace_path,
        )
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(
                {"bytes_per_expert": {str(layer): 5 * 1024 * 1024 for layer in range(args.n_layers)}},
                fh,
                indent=2,
            )
        trace_arg = trace_path
        src = "demo"
        if not args.manifest:
            args.manifest = str(manifest_path)
    else:
        if not args.trace:
            ap.error("需要 --trace 或 --demo")
        trace_arg = args.trace
        src = args.trace

    if args.manifest:
        with open(args.manifest, "r", encoding="utf-8") as fh:
            bpe = json.load(fh).get("bytes_per_expert", {})

    order, per_layer = group_by_token(parse_records(trace_arg), args.max_tokens)
    calls, freq, trans_flat, overlap_sum, overlap_count = collect_stats(order, per_layer)
    hot = build_hot_lists(freq, calls)
    transitions = build_transitions(trans_flat)
    temporal = overlap_sum / overlap_count if overlap_count else 0.0

    budgets = [float(b) for b in args.bank_budgets.split(",")]
    tier_budget = args.tier_budget_gib if args.tier_budget_gib is not None else budgets[0]

    hot_path = outdir / "hot_list.json"
    trans_path = outdir / "transitions.json"
    report_path = outdir / "report.md"
    hot_txt_path = outdir / "hot_list.txt"
    with open(hot_path, "w", encoding="utf-8") as fh:
        json.dump(hot, fh, indent=2)
    with open(trans_path, "w", encoding="utf-8") as fh:
        json.dump(transitions, fh, indent=2)
    write_report(report_path, hot_txt_path, order, per_layer, calls, freq, transitions, hot,
                 budgets, tier_budget, bpe, temporal, src)

    print(f"source              : {src}")
    print(f"tokens              : {len(order)}")
    print(f"layer calls         : {sum(calls.values())}")
    print(f"temporal locality   : {temporal:.4f}")
    print(f"hot_list            : {hot_path}")
    print(f"hot_list(L0 工件)   : {hot_txt_path}")
    print(f"transitions         : {trans_path}")
    print(f"report              : {report_path}")


if __name__ == "__main__":
    main()
