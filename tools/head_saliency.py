#!/usr/bin/env python3
"""
head_saliency.py — 静态 head 显著性探测（剪枝假说的权重侧预筛）

只读 BF16 权重（不跑 forward），对每个 attention head 计算静态贡献代理：
  KDA(v1): ‖W_o[head]‖  ‖W_q/k/v[head]‖  ‖dt_bias[head]‖  b_proj 行范数
  MLA(v2): ‖W_o[head]‖  ‖q_b[head]‖(content vs rope)  ‖kv_b[head]‖
             + kv_a rope 行范数（NoPE 假说下 rope 沉积是否死重)
跨 96 heads 的方差 = 剪枝空间的直接证据。无方差 → 证伪"冗余 head"。
纯 weight 范数, 无需 embed/forward, 秒级~分钟级。

用法:
  python3 tools/head_saliency.py --trunk-json trunk.json --trunk-bin trunk.bin \
         [--layers 0,30,60,3,47,92]   (默认 sample 6 层; --layers all = 全部 93 层)
  → results/head_saliency_<ts>.md  (人读) + results/head_saliency_<ts>.json (机读)
"""
import argparse, json, os, sys, time

import numpy as np

try:
    from probe_k3_fwd import Trunk, is_v2
except ImportError:
    from tools.probe_k3_fwd import Trunk, is_v2

DK = 128   # KDA d_k
QH = 192   # MLA q_b per-head (128 content + 64 rope)
KVH = 256  # MLA kv_b per-head (128 k + 128 v)

def row_norms(W, blk):
    """按每 blk 行一组算 Frobenius 范数 → [n_groups]。W 行按 head 分组。"""
    n, d = W.shape
    if n % blk != 0:
        blk = 1
    g = W.reshape(n // blk, blk, d)
    return np.linalg.norm(g.reshape(n // blk, blk * d), axis=1)

def col_norms(W, blk):
    """按每 blk 列一组 → [n_groups]。用于 o_proj 按 head 输出维度分组。"""
    n, d = W.shape
    if d % blk != 0:
        blk = 1
    g = W.reshape(n, d // blk, blk)
    return np.linalg.norm(g.reshape(n, d // blk, blk), axis=(0, 2))

def stats(v):
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
    """带符号权重向量(可为负): 只报位置/尺度, 不报范数比率。"""
    v = np.asarray(v, dtype=np.float64)
    if v.size == 0:
        return {"n": 0}
    return {"n": int(v.size), "min": float(v.min()), "max": float(v.max()),
            "mean": float(v.mean()), "std": float(v.std())}

def probe_kda(ti, L, ns):
    """返回 layer L 的 KDA head 显著性指标 dict。"""
    r = {"ver": "v1/KDA", "heads": 0}
    def get(sfx):
        for n in ns:
            if n.endswith(sfx):
                return ti.tensor(n)
        return None
    W_q, W_k, W_v = (get(f"{p}_proj.weight") for p in ("q", "k", "v"))
    W_o = get("o_proj.weight")
    dt = get("dt_bias")
    A = get("A_log")
    b = get("b_proj.weight")
    on = get("o_norm")
    if W_o is None:
        return None
    heads = W_o.shape[1] // DK
    if heads < 1:
        heads = W_o.shape[1]
    hb = DK if W_o.shape[1] % DK == 0 else 1
    on_h = col_norms(W_o, hb)                       # [heads]
    r["heads"] = int(heads)
    r["W_o_head_norm"] = stats(on_h)
    if W_q is not None:
        assert W_q.shape[0] % hb == 0, f"q_proj rows {W_q.shape[0]} % {hb}"
        r["W_q_head_norm"] = stats(row_norms(W_q, hb))
        r["W_k_head_norm"] = stats(row_norms(W_k, hb)) if W_k is not None else None
        r["W_v_head_norm"] = stats(row_norms(W_v, hb)) if W_v is not None else None
        # ‖o‖ 与 ‖qkv‖ 的跨 head 一致性 (log-log 相关)
        if W_k is not None:
            q = row_norms(W_q, hb); v = row_norms(W_v, hb)
            lg = (np.log(on_h + 1e-9), np.log((q * v) + 1e-9))
            if lg[0].std() > 1e-6 and lg[1].std() > 1e-6:
                r["corr_ln_o_ln_qv"] = float(np.corrcoef(lg[0], lg[1])[0, 1])
    if dt is not None:
        dtt = dt if dt.ndim == 2 else dt.reshape(-1, hb) if dt.ndim == 1 else dt
        r["dt_bias_head_norm"] = stats(row_norms(dtt, hb))
    if A is not None:
        r["A_log_channel"] = sstats(np.asarray(A))
    if b is not None:
        r["b_proj_head_norm"] = stats(row_norms(b, 1))
    if on is not None:
        r["o_norm_channel"] = sstats(np.asarray(on))
    return r

def probe_mla(ti, L, ns):
    r = {"ver": "v2/MLA", "heads": 0}
    def get(sfx):
        for n in ns:
            if n.endswith(sfx):
                return ti.tensor(n)
        return None
    W_o    = get("o_proj.weight")
    qb     = get("q_b_proj.weight")
    kvb    = get("kv_b_proj.weight")
    qa     = get("q_a_proj.weight")
    kva    = get("kv_a_proj_with_mqa.weight")
    kvn    = get("kv_a_layernorm.weight")
    qan    = get("q_a_layernorm.weight")
    if W_o is None:
        return None
    heads = W_o.shape[1] // DK if W_o.shape[1] % DK == 0 else W_o.shape[1]
    r["heads"] = int(heads)
    hb = DK if W_o.shape[1] % DK == 0 else 1
    r["W_o_head_norm"] = stats(col_norms(W_o, hb))
    if qb is not None:
        hq = qb.shape[0] // QH if qb.shape[0] % QH == 0 else 1
        qb_h = qi = qb.reshape(hq, QH, qb.shape[1]) if hq else np.zeros((0,))
        if hq:
            cont = np.linalg.norm(qb_h[:, :128, :].reshape(hq, 128 * qb.shape[1]), axis=1)
            rope = np.linalg.norm(qb_h[:, 128:, :].reshape(hq, 64 * qb.shape[1]), axis=1)
            r["q_b_head_norm"] = stats(np.linalg.norm(qb_h.reshape(hq, QH * qb.shape[1]), axis=1))
            r["q_b_content_norm"] = stats(cont)
            r["q_b_rope_norm"] = stats(rope)
            r["q_b_rope_vs_content"] = float(rope.sum() / (cont.sum() + 1e-12))
    if kvb is not None:
        hk = kvb.shape[0] // KVH if kvb.shape[0] % KVH == 0 else 1
        if hk:
            kvb_h = kvb.reshape(hk, KVH, kvb.shape[1])
            kpart = np.linalg.norm(kvb_h[:, :128, :].reshape(hk, 128 * kvb.shape[1]), axis=1)
            vpart = np.linalg.norm(kvb_h[:, 128:, :].reshape(hk, 128 * kvb.shape[1]), axis=1)
            r["kv_b_head_norm"] = stats(np.linalg.norm(kvb_h.reshape(hk, KVH * kvb.shape[1]), axis=1))
    if kva is not None:
        # rope 死重检查：kv_a 后 64 行(rope) 是否近零范数
        nrow = kva.shape[0]
        if nrow > 512:
            cont = np.linalg.norm(kva[:512, :]); rope = np.linalg.norm(kva[512:, :])
            r["kv_a_rope_row_norm"] = float(rope)
            r["kv_a_content_row_norm"] = float(cont)
            r["kv_a_rope_vs_content"] = float(rope / (cont + 1e-12))
        else:
            r["kv_a_total_norm"] = float(np.linalg.norm(kva))
    if kvn is not None:
        r["kv_a_layernorm"] = sstats(np.asarray(kvn))
    if qan is not None:
        r["q_a_layernorm"] = sstats(np.asarray(qan))
    if qa is not None:
        r["q_a_latent_norm"] = float(np.linalg.norm(qa))
    return r

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trunk-json", required=True)
    ap.add_argument("--trunk-bin", required=True)
    ap.add_argument("--layers", default="0,30,60,3,47,92",
                    help="逗号分隔层号, 或 all")
    args = ap.parse_args()

    t0 = time.time()
    ti = Trunk(args.trunk_json, args.trunk_bin)
    all_layers = sorted(ti.layers)
    layers = all_layers if args.layers.strip() == "all" else \
        [int(x) for x in args.layers.split(",") if x.strip()]
    print(f"[{time.time()-t0:.1f}s] 索引 {len(ti.map)} 张量; 全部层 {len(all_layers)}; 本次扫描 {layers}")

    os.makedirs("results", exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    out = {"scan": {"layers": layers, "ts": ts}, "layers": {}}
    for L in layers:
        ns = ti.layer_names(L)
        if not ns or not any("self_attn" in n for n in ns):
            continue
        v2 = any(is_v2(n) for n in ns)
        r = probe_mla(ti, L, ns) if v2 else probe_kda(ti, L, ns)
        if r is None:
            continue
        out["layers"][str(L)] = r
        ver, h = r["ver"], r["heads"]
        o = r.get("W_o_head_norm") or {}
        line = f"[{time.time()-t0:.1f}s] L{L:>3} {ver} heads={h}"
        if "mean" in o:
            line += (f"  ‖W_o‖: mean={o['mean']:.3g} cv={o['cv']:.2g} "
                     f"max/min={o['max_min_ratio']:.1f} <0.1max={o['frac_below_0.1max']*100:.0f}% "
                     f"top/bot={o['top10_vs_bot10']:.1f}")
        print(line)
    print(f"[{time.time()-t0:.1f}s] 完成 → results/head_saliency_{ts}.md/.json")

    with open(f"results/head_saliency_{ts}.json", "w") as f:
        json.dump(out, f, indent=1)

    md = ["# head_saliency " + ts, "",
          f"scan layers: {layers}   trunk={args.trunk_bin}", "## per-layer summary"]
    for L, r in out["layers"].items():
        md.append(f"\n### L{L} ({r['ver']}, {r['heads']} heads)")
        for k, v in r.items():
            if k in ("ver", "heads") or v is None:
                continue
            if isinstance(v, dict):
                md.append(f"- **{k}**: " + ", ".join(f"{kk}={vv:.3g}" for kk, vv in v.items()))
            else:
                md.append(f"- **{k}**: {v:.4g}")
    with open(f"results/head_saliency_{ts}.md", "w") as f:
        f.write("\n".join(md) + "\n")

if __name__ == "__main__":
    main()