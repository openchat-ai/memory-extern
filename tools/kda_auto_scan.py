#!/usr/bin/env python3
"""
全自动张量分解可行性扫描器(傻瓜版)—— 不再需要手动挑 --key。
自动遍历权重里所有候选稠密矩阵, 每个都跑【k从4→满】的头结构/低秩曲线,
自动识别"断崖(可压)" vs "平滑满秩(墙)", 并自动给结论 + 归类作用。

用法(仅需权重路径, 架构自动判断):
  python3 tools/kda_auto_scan.py --ckpt model.safetensors [--arch smol]
输出: 每矩阵一条 = 有效秩 / 断崖k / 类别(qkv门|route|FFN|其他) / 判定(可压|墙|需大k)
"""
import argparse, math, sys

# 每类矩阵的"期望"(写清楚, 不再让你瞎测)
MAT_CLASS = {
    # 关键: qkv/o 是"产生h_in"的满秩映射 —— §12 早就预言它们满秩, 失败不意外
    "qkv":   ("KDA多头映射", "产生h_in",    "期望: 满秩墙(头独立[Per-Head Muon]). 若可压才是惊喜"),
    "out_gate": ("输出门",    "h_in后处理",  "中低熵, 可能可压"),
    "latent":("MLA/升维降维", "低秩latent",  "MLA特意低秩压缩, 期望可压(如K3的latent)"),
    "ffn":   ("SiTU-GLU升降", "前馈",        "经验: 部分可压"),
    "router":("route打分",   "选top-k",      "本就极小(H*num_experts), 不需张量分解"),
    "embed": ("词表",         "查找表",       "行独立, 不可压(§11)"),
}

def classify(name):
    n = name.lower()
    if "router" in n or n.endswith(".gate.weight") or "e_score_correction_bias" in n:
        return "router"
    if "embed" in n or "tok_embeddings" in n or "lm_head" in n:
        return "embed"
    if ("latent" in n or "kv_down" in n or "k_up" in n or "v_up" in n or "w_a" in n
            or "f_a_proj" in n or "f_b_proj" in n or ".b_proj" in n or ".g_proj" in n):
        return "latent"
    if "up_proj" in n or "down_proj" in n or "w1" in n or "w3" in n or "w2" in n or "ffn" in n:
        return "ffn"
    if "out_proj" in n or "gate_proj" in n:
        return "out_gate"
    if "q_proj" in n or "k_proj" in n or "v_proj" in n:
        return "qkv"
    return "other"

def robustness_curve(M):
    """对矩阵 M[rows, cols] 扫 k=4→满, 返回各k相对误差 + 奇异值谱. 简洁版"""
    import torch
    W = M.float()
    s = torch.linalg.svdvals(W)
    total = (s * s).sum()
    out = []
    ks = [4, 8, 16, 32, 64, 128, 256, 512, min(1024, len(s))]
    for k in dict.fromkeys(ks):
        if k > len(s): continue
        cap = (s[:k] * s[:k]).sum() / total
        rel = math.sqrt(max(0.0, 1 - cap))
        out.append((k, rel))
    return out, s

def parse_curve(curve, s, rows):
    """自动判 断崖 / 平滑 / 需大k"""
    total = (s * s).sum()
    # 找"断崖": 相对误差从>0.5 突然降到<0.15 的前后k差小
    klow, rel0 = curve[0]
    # 检查奇异值谱是否在某处骤降
    drop = None
    if len(s) > 2:
        for i in range(len(s) - 1):
            if s[i + 1] / (s[i] + 1e-9) < 0.05 and s[i] > 1e-6:
                drop = i + 1  # 奇异值断崖位置(从1计数)
                break
    # 判定
    rel_at_quarter = None
    for k, rel in curve:
        if k >= max(1, rows // 4):
            rel_at_quarter = rel; break
    if rel_at_quarter is None: rel_at_quarter = 1.0
    if drop is not None and drop <= rows // 4:
        verdict = f"可压(断崖@k={drop}, 近无损进入低秩)"
    elif rel_at_quarter < 0.15:
        verdict = "可压(1/4维捕获>85%能量)"
    elif rel_at_quarter > 0.6:
        verdict = "满秩墙(1/4维误差>60%) 推不可压"
    else:
        verdict = f"中等(1/4维误差{rel_at_quarter:.2f}) 需权衡"
    return drop, rel_at_quarter, verdict

def load_index_cands(index_path, layer=None, maxrows=0):
    """多shard模式: 读 k3_index.json, 按需 safe_open 取矩阵, 支持 --layer 过滤, 跳过量化U8"""
    import json
    from safetensors import safe_open
    idx = json.load(open(index_path))
    pre = "language_model.model.layers."
    cands = []
    for k, meta in idx.items():
        if layer is not None and not (k.startswith(pre) and k[len(pre):].startswith(f"{layer}.")):
            continue
        if meta.get("dtype") == "U8":
            continue
        shape = meta.get("shape", [])
        if len(shape) != 2:
            continue
        if maxrows and max(shape) > maxrows:
            continue
        cls = classify(k)
        if cls == "other":
            continue
        shard = meta["shard"]
        try:
            with safe_open(f"/model/{shard}", framework="pt") as f:
                v = f.get_tensor(k)
        except Exception as e:
            print(f"  [skip] {k}: {e}")
            continue
        cands.append((k, cls, v))
    return cands

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True, help="safetensors文件 或 k3_index.json")
    ap.add_argument("--arch", choices=["auto", "smol", "k3"], default="auto")
    ap.add_argument("--max", type=int, default=0, help="最多扫几个矩阵(0=全)")
    ap.add_argument("--layer", type=int, default=None, help="只扫该层(layers.N.)")
    ap.add_argument("--maxrows", type=int, default=0, help="跳过任意维>maxrows的矩阵(0=不跳)")
    o = ap.parse_args()
    import torch
    if o.ckpt.endswith(".json"):
        cands = load_index_cands(o.ckpt, layer=o.layer, maxrows=o.maxrows)
    else:
        from safetensors.torch import load_file
        sd = load_file(o.ckpt)
        cands = []
        for k, v in sd.items():
            if v.ndim != 2: continue
            cls = classify(k)
            if cls == "other": continue
            cands.append((k, cls, v))
    if o.max: cands = cands[:o.max]
    if not cands:
        print("没找到候选矩阵(检查 --layer/--maxrows 过滤)。")
        return
    print(f"扫描 {len(cands)} 个矩阵, 每个跑 k→满 曲线\n")
    print(f"{'key':<40}{'类别':<8}{'shape':>12}{'断崖':>6}{'1/4误差':>9}  判定")
    results = []
    for k, cls, v in cands:
        curve, s = robustness_curve(v)
        drop, rq, verdict = parse_curve(curve, s, v.shape[0])
        cls_info = MAT_CLASS.get(cls, ("", "", ""))[0]
        results.append((cls, verdict, k))
        print(f"{k[:40]:<40}{cls:8}{str(list(v.shape)):>12}"
              f"{str(drop) if drop else '-':>6}"
              f"{rq:>9.2f}  {verdict} [{cls_info}]")

    print("\n=== 作用/期望表(删掉前先看这个) ===")
    for c, (disp, role, exp) in MAT_CLASS.items():
        found = [r for r in results if r[0] == c]
        print(f"[{c:8}] {disp} | {role} | {exp} | 现存 {len(found)} 个")
        for _, vd, k in found:
            print(f"         {vd}  <- {k[:60]}")
    print("\n判定总纲:")
    print("  qkv 满秩墙  = §12 预言成立, 张量分解对'产生h_in'压不动 → 走路径3(训router)")
    print("  latent 可压 = MLA 低秩latent, 真能压 → 这部分张量分解仍可用")
    print("  out_gate/ffn 可压 = 次要压缩收益")

if __name__ == "__main__":
    main()
