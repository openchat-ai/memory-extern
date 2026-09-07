#!/usr/bin/env python3
"""
head_saliency.py — 静态显著性探测 v2（head 级 + MoE 级 + 层金字塔）

只读 BF16/F32 权重（不跑 forward），三套代理：

  A. head 级 (KDA/MLA self_attn)：
     ‖W_o[head]‖ ‖W_q/k/v[head]‖ ‖dt_bias[head]‖ b_proj 行范数
     MLA: q_b content vs rope 范数 / kv_a rope 行范数 (NoPE 死重检查)
  B. MoE 级 (block_sparse_moe)：
     gate 896 行范数 (专家可剪性: 低范数行=路由常年不选)
     routed_expert_latent ‖W↓‖ ‖W↑‖   shared_experts 三矩阵范数
  C. 层金字塔 (所有层):
     Δ层 importance = mean‖W_o[head]‖ → Early-exit 可行性:
       归一化累计 P(k), exit@0.9/0.95, log-importance 斜率, 头部集中度

张量名对齐 k3_head_dims_data.md 实测 (layer.0 为唯一 dense MLP 层, 其余 block_sparse_moe)。
dt_bias / A_log / o_norm / conv1d / gate_bias 为 F32, 其余 BF16。

用法:
  python3 tools/head_saliency.py --trunk-json trunk.json --trunk-bin trunk.bin \
         [--layers 0,30,60,3,47,92|all]
  → results/head_saliency_<ts>.md / .json
"""
import argparse, json, os, sys, time

import numpy as np

try:
    from probe_k3_fwd import Trunk, is_v2
except ImportError:
    from tools.probe_k3_fwd import Trunk, is_v2

DK = 128   # KDA d_k / MLA o 输出
QH = 192   # MLA q_b per-head (128 content + 64 rope)
KVH = 256  # MLA kv_b per-head (128 k + 128 v)

def row_norms(W, blk=1):
    """按每 blk 行一组算 Frobenius 范数 → [n_groups]。W 行按 head/expert 分组。"""
    n, d = W.shape
    if n % blk != 0:
        blk = 1
    return np.linalg.norm(W.reshape(n // blk, blk, d).reshape(n // blk, blk * d), axis=1)

def col_norms(W, blk):
    """按每 blk 列一组 → [d/blk]。o_proj 输出维度按 head 分组。"""
    n, d = W.shape
    if d % blk != 0:
        blk = 1
    return np.linalg.norm(W.reshape(n, d // blk, blk), axis=(0, 2))

def stats(v):
    """非负数组 (范数) 的统计 + 剪枝代理。"""
    v = np.asarray(v, dtype=np.float64)
    if v.size == 0:
        return {"n": 0}
    denom = v.max() if v.max() > 0 else 1.0
    return {
        "n": int(v.size),
        "min": float(v.min()), "max": float(v.max()), "mean": float(v.mean()),
        "std": float(v.std()), "cv": float(v.std() / (v.mean() + 1e-12)),
        "max_min_ratio": float(v.max() / (v.min() + 1e-12)),
        "frac_below_0.1max": float((v < 0.1 * denom).mean()),
        "frac_below_0.01max": float((v < 0.01 * denom).mean()),
        "top10_vs_bot10": float(
            (np.sort(v)[-max(1, v.size // 10):].mean() + 1e-12) /
            (np.sort(v)[:max(1, v.size // 10)].mean() + 1e-12)),
    }

def sstats(v):
    """带符号数组 (可能为负的权重向量): 只报位置/尺度。"""
    v = np.asarray(v, dtype=np.float64)
    if v.size == 0:
        return {"n": 0}
    return {"n": int(v.size), "min": float(v.min()), "max": float(v.max()),
            "mean": float(v.mean()), "std": float(v.std())}

# ── A. head 级 ─────────────────────────────────────────────
def probe_kda(ti, L, ns):
    def get(sfx):
        for n in ns:
            if n.endswith(sfx):
                return ti.tensor(n)
        return None
    W_q = get(".self_attn.q_proj.weight")
    W_k = get(".self_attn.k_proj.weight")
    W_v = get(".self_attn.v_proj.weight")
    W_o = get(".self_attn.o_proj.weight")
    dt  = get(".self_attn.dt_bias")
    A   = get(".self_attn.A_log")
    b   = get(".self_attn.b_proj.weight")
    on  = get(".self_attn.o_norm.weight")
    if W_o is None and W_q is None:
        return None
    hb = DK if (W_o is not None and W_o.shape[1] % DK == 0) else 1
    r = {"ver": "v1/KDA", "heads": int(W_o.shape[1] // hb) if W_o is not None else 0}
    if W_o is not None:
        o_arr = col_norms(W_o, hb)
        r["W_o_head_norm"] = stats(o_arr)
    if W_q is not None:
        assert W_q.shape[0] % hb == 0
        r["W_q_head_norm"] = stats(row_norms(W_q, hb))
        if W_k is not None:
            r["W_k_head_norm"] = stats(row_norms(W_k, hb))
            r["W_v_head_norm"] = stats(row_norms(W_v, hb))
            q = row_norms(W_q, hb); v = row_norms(W_v, hb)
            if W_o is not None and len(o_arr) == len(q) and o_arr.std() > 0 and (q * v).std() > 0:
                r["corr_ln_o_ln_qv"] = float(
                    np.corrcoef(np.log(o_arr + 1e-9), np.log(q * v + 1e-9))[0, 1])
    if dt is not None:
        r["dt_bias_head_norm"] = stats(row_norms(dt.reshape(len(dt) // hb, hb), hb))
    if A is not None:
        r["A_log_channel"] = sstats(np.asarray(A))
    if b is not None:
        r["b_proj_head_norm"] = stats(row_norms(b, 1))
    if on is not None:
        r["o_norm_channel"] = sstats(np.asarray(on))
    return r

def probe_mla(ti, L, ns):
    def get(sfx):
        for n in ns:
            if n.endswith(sfx):
                return ti.tensor(n)
        return None
    W_o   = get(".self_attn.o_proj.weight")
    qb    = get(".self_attn.q_b_proj.weight")
    kvb   = get(".self_attn.kv_b_proj.weight")
    kva   = get(".self_attn.kv_a_proj_with_mqa.weight")
    kvn   = get(".self_attn.kv_a_layernorm.weight")
    qan   = get(".self_attn.q_a_layernorm.weight")
    qa    = get(".self_attn.q_a_proj.weight")
    if W_o is None and qb is None:
        return None
    hb = DK if (W_o is not None and W_o.shape[1] % DK == 0) else 1
    r = {"ver": "v2/MLA", "heads": int(W_o.shape[1] // hb) if W_o is not None else 0}
    if W_o is not None:
        r["W_o_head_norm"] = stats(col_norms(W_o, hb))
    if qb is not None:
        hq = qb.shape[0] // QH if qb.shape[0] % QH == 0 else 1
        if hq:
            qb_h = qb.reshape(hq, QH, qb.shape[1])
            cont = np.linalg.norm(qb_h[:, :128, :].reshape(hq, 128 * qb.shape[1]), axis=1)
            rope = np.linalg.norm(qb_h[:, 128:, :].reshape(hq, 64 * qb.shape[1]), axis=1)
            r["q_b_head_norm"] = stats(np.linalg.norm(qb_h.reshape(hq, QH * qb.shape[1]), axis=1))
            r["q_b_content_norm"] = stats(cont)
            r["q_b_rope_norm"] = stats(rope)
            r["q_b_rope_vs_content"] = float(rope.sum() / (cont.sum() + 1e-12))
    if kvb is not None:
        hk = kvb.shape[0] // KVH if kvb.shape[0] % KVH == 0 else 1
        if hk:
            r["kv_b_head_norm"] = stats(np.linalg.norm(kvb.reshape(hk, KVH, -1), axis=(1, 2)))
    if kva is not None and kva.shape[0] > 512:
        cont = np.linalg.norm(kva[:512, :]); rope = np.linalg.norm(kva[512:, :])
        r["kv_a_rope_row_norm"] = float(rope)
        r["kv_a_content_row_norm"] = float(cont)
        r["kv_a_rope_vs_content"] = float(rope / (cont + 1e-12))
    elif kva is not None:
        r["kv_a_total_norm"] = float(np.linalg.norm(kva))
    if kvn is not None:
        r["kv_a_layernorm"] = sstats(np.asarray(kvn))
    if qan is not None:
        r["q_a_layernorm"] = sstats(np.asarray(qan))
    if qa is not None:
        r["q_a_latent_norm"] = float(np.linalg.norm(qa))
    return r

# ── B. MoE 级 ──────────────────────────────────────────────
def probe_moe(ti, L, ns):
    out = {}
    def get(sfx):
        for n in ns:
            if n.endswith(sfx):
                return ti.tensor(n)
        return None
    g = get(".block_sparse_moe.gate.weight")
    gm = get(".mlp.gate_proj.weight")         # dense 层 (layer 0)
    if g is None and gm is None:
        return None
    out["type"] = "dense_mlp" if gm is not None else "latent_moe"
    if g is not None:
        rw = row_norms(g, 1)                   # 896 专家路由行范数
        out["gate"] = {
            "expert_row_norm": stats(rw),
            "gat_param": {"shape": list(g.shape)},
        }
    rd = get(".block_sparse_moe.routed_expert_down_proj.weight")
    ru = get(".block_sparse_moe.routed_expert_up_proj.weight")
    rn = get(".block_sparse_moe.routed_expert_norm.weight")
    if rd is not None:
        out["routed_latent_down"] = float(np.linalg.norm(rd))
        out["routed_latent_up"] = float(np.linalg.norm(ru)) if ru is not None else None
        out["routed_latent_norm_w"] = sstats(np.asarray(rn)) if rn is not None else None
    sg = get(".shared_experts.gate_proj.weight")
    su = get(".shared_experts.up_proj.weight")
    sd = get(".shared_experts.down_proj.weight")
    if sg is not None:
        a = np.linalg.norm(sg); b = np.linalg.norm(su); c = np.linalg.norm(sd)
        out["shared_expert"] = {"gate": float(a), "up": float(b), "down": float(c),
                                "cv_of3": float(np.std([a, b, c]) / (np.mean([a, b, c]) + 1e-12))}
    if gm is not None:
        gu = get(".mlp.up_proj.weight")
        gd = get(".mlp.down_proj.weight")
        a = np.linalg.norm(gm); b = np.linalg.norm(gu); c = np.linalg.norm(gd)
        out["dense_mlp"] = {"gate": float(a), "up": float(b), "down": float(c)}
    return out

# ── C. 聚合/金字塔 ─────────────────────────────────────────
def pyramid_report(rows):
    """rows: [(layer, ver, o_mean, o_cv, gate_cv, routed_lat, shared_g)), ...] 非空 o_mean"""
    n = len(rows)
    if n == 0:
        return {}
    layers = np.array([r[0] for r in rows], dtype=np.float64)
    imp = np.array([r[2] for r in rows], dtype=np.float64)
    imp_n = imp / (imp.sum() + 1e-12)
    cum = np.cumsum(imp_n)
    def exit_at(q):
        k = int(np.searchsorted(cum, q))
        return int(layers[min(k, n - 1)]), float(cum[k])
    e09 = exit_at(0.90); e095 = exit_at(0.95)
    # log-importance 随层的斜率（金字塔扁平度; 负=末段衰减→可早退）
    slope = float(np.polyfit(layers, np.log(imp + 1e-9), 1)[0]) if n >= 3 else None
    # 三段 (首/中/尾) 均值
    n3 = max(1, n // 3)
    seg = lambda sl: float(imp[sl].mean())
    return {
        "n_scan": n,
        "layer_range": [int(layers.min()), int(layers.max())],
        "exit_at_P0.90": e09, "exit_at_P0.95": e095,
        "log_imp_slope": slope,
        "seg_first": seg(slice(0, n3)), "seg_mid": seg(slice(n3, 2 * n3)),
        "seg_tail": seg(slice(2 * n3, n)),
        "top10pct_share": float(imp_n[np.argsort(imp)[-max(1, n // 10):]].sum()),
        "imp_cv": float(imp.std() / (imp.mean() + 1e-12)),
    }

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trunk-json", required=True)
    ap.add_argument("--trunk-bin", required=True)
    ap.add_argument("--layers", default="0,30,60,3,47,92", help="逗号分隔层号或 all")
    args = ap.parse_args()
    t0 = time.time()
    ti = Trunk(args.trunk_json, args.trunk_bin)
    all_layers = sorted(ti.layers)
    layers = all_layers if args.layers.strip() == "all" else \
        [int(x) for x in args.layers.split(",") if x.strip()]
    print(f"[{time.time()-t0:.1f}s] 索引 {len(ti.map)} 张量; 全层 {len(all_layers)}; 扫描 {layers}")
    os.makedirs("results", exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    out = {"scan": {"layers": layers, "ts": ts}, "layers": {}, "pyramid": {}, "moe": {}}
    rows = []
    for L in layers:
        ns = ti.layer_names(L)
        if not ns or not any("self_attn" in n or "mlp" in n or "moe" in n for n in ns):
            continue
        v2 = any(is_v2(n) for n in ns)
        prob = probe_mla(ti, L, ns) if v2 else probe_kda(ti, L, ns)
        if prob is None:
            continue
        hd = prob.get("W_o_head_norm") or {}
        moe = probe_moe(ti, L, ns)
        if moe is not None:
            out["moe"][str(L)] = moe
        out["layers"][str(L)] = prob
        # pyramid 行
        o_m = hd.get("mean"); o_cv = hd.get("cv")
        gate_cv = None; routed_lat = None
        if moe:
            gk = moe.get("gate", {})
            gate_cv = gk.get("expert_row_norm", {}).get("cv") if isinstance(gk, dict) else None
            routed_lat = moe.get("routed_latent_down")
        rows.append((L, prob["ver"], o_m if o_m is not None else float("nan"),
                     o_cv if o_cv is not None else float("nan"),
                     gate_cv, routed_lat))
        print(f"[{time.time()-t0:.1f}s] L{L:>3} {prob['ver']} heads={prob['heads']}"
              + (f"  ‖W_o‖mean={o_m:.3g} cv={o_cv:.2g}" if o_m is not None else "")
              + (f"  gate_cv={gate_cv:.2g}" if gate_cv else ""))
    # 金字塔
    valid = [r for r in rows if r[2] == r[2]]  # 去 NaN
    if valid:
        pyr = pyramid_report(valid)
        out["pyramid"] = pyr
        print("\n── 层金字塔 (Early-exit) ──")
        print(f"  scan={pyr['n_scan']} 层  范围 {pyr['layer_range']}")
        print(f"  exit@P0.90 → lay {pyr['exit_at_P0.90']} | P0.95 → lay {pyr['exit_at_P0.95']}")
        print(f"  log-importance 斜率 = {pyr['log_imp_slope']} (负=末段衰减→早退可行)")
        print(f"  首/中/尾段 ‖W_o‖均值 = {pyr['seg_first']:.3g} / {pyr['seg_mid']:.3g} / {pyr['seg_tail']:.3g}")
        print(f"  top10%层承担重要度 = {pyr['top10pct_share']*100:.0f}%")
    with open(f"results/head_saliency_{ts}.json", "w") as f:
        json.dump(out, f, indent=1)
    md = [f"# head_saliency {ts}", "", f"scan: {layers}   trunk={args.trunk_bin}",
          "## 层金字塔", "", "```", json.dumps(out.get("pyramid", {}), indent=1), "```"]
    for L, r in out["layers"].items():
        md.append(f"\n### L{L} ({r['ver']}, {r['heads']} heads)")
        for k, v in r.items():
            if k in ("ver", "heads") or v is None:
                continue
            if isinstance(v, dict):
                md.append(f"- **{k}**: " + ", ".join(f"{kk}={vv:.3g}" for kk, vv in v.items()))
            else:
                md.append(f"- **{k}**: {v:.4g}")
    if out.get("moe"):
        md.append("\n## MoE")
        for L, m in out["moe"].items():
            md.append(f"\n### L{L} {m.get('type','')}")
            for k, v in m.items():
                if k == "type":
                    continue
                if isinstance(v, dict):
                    # 每个子项可能是 stats dict (有 n/mean) 或单值 dict (shape)
                    if "n" in v:          # stats-like
                        md.append(f"- **{k}**: " + ", ".join(f"{kk}={vv:.3g}" for kk, vv in v.items()))
                    else:
                        md.append(f"- **{k}**: {json.dumps(v)}")
                else:
                    md.append(f"- **{k}**: {v:.4g}" if isinstance(v, (int, float)) else f"- **{k}**: {v}")
    with open(f"results/head_saliency_{ts}.md", "w") as f:
        f.write("\n".join(md) + "\n")
    print(f"[{time.time()-t0:.1f}s] 完成 → results/head_saliency_{ts}.md / .json")

if __name__ == "__main__":
    main()