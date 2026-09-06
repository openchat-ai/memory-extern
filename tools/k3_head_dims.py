#!/usr/bin/env python3
"""
K3 checkpoint 结构清单 —— 纯 stdlib, 只读 safetensors JSON 头(不加载权重)。
用途:
  1. 解头维度谜题: 看 W_q/W_k 的 [out, in] 输出形状 → 推断真实 head/state 维度
     (官方表: 96 heads, hidden 7168 → 7168/96 = 74.67 非整数 → 必查实际形状)
  2. 摸清 "trunk 55G/100G" 成分: 按类别汇总参数数/字节数, 看 attention/latent/
     expert(shared+routed)/router/embed 各占多少, 与官方表1(激活104.2B)对账。
用法:
  python3 tools/k3_head_dims.py --ckpt model.safetensors
  python3 tools/k3_head_dims.py --dir .            # 扫描 index-*.safetensors 全部分片
"""
import argparse, glob, json, os, sys
from collections import defaultdict

def shapes_from(path):
    with open(path, "rb") as f:
        n = int.from_bytes(f.read(8), "little")
        hdr = json.loads(f.read(n).decode("utf-8"))
    return path, hdr

def classify(t):
    n = t.lower()
    if "embed" in n or "tok_emb" in n or "lm_head" in n or "output.weight" in n:
        return "embed/output"
    if "router" in n or "e_score" in n or "gating" in n or "route" in n:
        return "router"
    if "shared" in n or "experts" in n or "moe" in n or "expert" in n:
        return "moe_experts"
    if "latent" in n or "kv_down" in n or "kv_up" in n or "k_up" in n or "v_up" in n \
            or "w_down" in n or "w_up" in n:
        return "latent_moe"
    if "alpha" in n or "decay" in n or "w_a" in n or "a_proj" in n:
        return "kda_alpha_gate"
    if "beta" in n or "write" in n:
        return "kda_beta_write"
    if "gate" in n or "g_proj" in n:
        return "output_gate"
    if "shortconv" in n or "short_conv" in n or "conv1d" in n:
        return "shortconv"
    if "q_proj" in n or "k_proj" in n or "v_proj" in n or "o_proj" in n \
            or "out_proj" in n or "attn" in n:
        return "attn_qkv_o"
    if "norm" in n or "rms" in n or "ln" in n:
        return "norms"
    if "vit" in n or "patch" in n or "moon" in n or "vision" in n:
        return "vision"
    return "other"

def fmt(b):
    for u in ("B", "KB", "MB", "GB", "TB"):
        if b < 1024 or u == "TB":
            return f"{b:.1f}{u}"
        b /= 1024

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", help="单个 safetensors 文件路径")
    ap.add_argument("--dir", help="目录, 扫描 *safetensors 全部文件")
    args = ap.parse_args()

    files = []
    if args.dir:
        files = sorted(glob.glob(os.path.join(args.dir, "*.safetensors")))
    elif args.ckpt:
        files = [args.ckpt]
    if not files:
        sys.exit("没有可用的 safetensors, 用 --ckpt 或 --dir")

    per_cat = defaultdict(lambda: [0, 0])   # cat -> [params, bytes]
    attn_shapes = []                        # 保留 attention 相关完整形状供人读
    all_names = set()

    for p in files:
        path, hdr = shapes_from(p)
        print(f"\n===== {os.path.basename(path)} ({fmt(os.path.getsize(path))}) =====")
        skip = hdr.get("__metadata__", {})
        for name, meta in hdr.items():
            if name == "__metadata__":
                continue
            shape = meta["shape"]; dt = meta["dtype"]
            elems = 1
            for s in shape:
                elems *= s
            bpe = {"F32": 4, "F16": 2, "BF16": 2, "I8": 1, "I4": 1, "I32": 4,
                   "MXFP4": 1, "MXFP8": 1}.get(dt.upper(), 4)
            nbytes = elems * bpe
            cat = classify(name)
            per_cat[cat][0] += elems
            per_cat[cat][1] += nbytes
            all_names.add(name)
            if cat.startswith("attn") or cat.startswith("kda") or cat == "latent_moe" \
                    or cat == "output_gate" or cat == "shortconv":
                last = ".".join(name.rsplit(".", 1)[-1].split(".")[-3:])
                attn_shapes.append(f"  {last:<60} {dt:<6} {'x'.join(map(str, shape))}"
                                   f"  {elems/1e6:.1f}M {fmt(nbytes)}  [{cat}]")
        # 打印 metadata 里可能存在的配置(内含 head_dim 等)
        if skip:
            print(f"  __metadata__ keys: {sorted(skip)[:12]}")

    print("\n\n===== attention 相关张量(全形状, 判断真实 head 维度用) =====")
    for s in sorted(set(attn_shapes)):
        print(s)

    print("\n===== 参数/字节 类别汇总 (对账 55G trunk 来源) =====")
    tot_p = tot_b = 0
    for cat in sorted(per_cat):
        p, b = per_cat[cat]
        if p == 0:
            continue
        tot_p += p; tot_b += b
        print(f"  {cat:<14} 参数={p/1e9:8.3f}B  字节={fmt(b):>10}")
    print(f"  {'TOTAL':<14} 参数={tot_p/1e9:8.3f}B  字节={fmt(tot_b):>10}")

    print(f"\n统计: {len(all_names)} 个张量, {len(files)} 个分片.")

if __name__ == "__main__":
    main()