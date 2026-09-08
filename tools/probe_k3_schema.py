#!/usr/bin/env python3
"""
probe_k3_schema.py — 宽容式 trunk.json schema 自动探测（探针前奏）

目的：trunk.bin + trunk.json 的真实结构未知，先跑本脚本把 schema 探测出来，
     判据清晰后 forward 探针才能对齐。不硬编码任何 key 名。

自动探测：
  1. trunk.json 顶层是 dict 还是 list；条目里 tensor 元字段叫什么
     （name / offset / off / data_offset / byte_offset / start ...,
      shape / sizes / dims / [H,W],
      dtype / elem_type / format / bytes / byte_size ...）
  2. 按 layer 分组 + 类别分类（KDA v1 vs MLA v2），打印代表层的张量清单
  3. 对每个条目核对：shape×dtype 字节 vs 存储字段，offset 是否越界 trunk.bin
  4. clamp/coerce 出"解析后的统一 schema"（探针 forward 直接复用）

用法：
  python3 tools/probe_k3_schema.py --trunk-json /path/trunk.json \
         [--trunk-bin /path/trunk.bin] [--embed-json /path/model.index.json]
输出：解析结果 → 打印代表张量 + resolved schema 摘要。
"""
import argparse, json, os, sys

# dtype → 每元素字节（包容常见拼写/大小写）
DTYPE_BYTES = {
    "bf16": 2, "bfloat16": 2, "float16": 2, "fp16": 2, "f16": 2,
    "fp32": 4, "float32": 4, "f32": 4, "int8": 1, "i8": 1,
    "int32": 4, "i32": 4, "uint8": 1, "u8": 1, "f64": 8, "float64": 8,
}

# shape 字段的候选 key（按优先级）
SHAPE_KEYS = ["shape", "shape_list", "dims", "sizes", "szs", "sz", "h_w", "hw"]
OFFSET_KEYS = ["offset", "off", "byte_offset", "data_offset", "start", "addr",
               "begin", "position", "pos"]
SIZE_KEYS = ["bytes", "byte_size", "size", "nbytes", "mem", "len"]
DTYPE_KEYS = ["dtype", "elem_type", "format", "type", "dtype_str", "precision"]
NAME_KEYS = ["name", "key", "tensor", "tensor_name", "id"]


def probe_shape(v):
    """从字典值里提出 (list_of_ints) 形状，宽容解析。返回 None 或 [int,...]。"""
    if isinstance(v, list):
        if all(isinstance(x, (int, float)) for x in v):
            return [int(x) for x in v]
        # 可能是 dict 列表（每个张量子条目）
        return None
    if isinstance(v, dict):
        for k in SHAPE_KEYS:
            if k in v:
                return probe_shape(v[k])
        # 常见 {'H':..,'W':..} / {'rows':..,'cols':..}
        if all(k in v for k in ("rows", "cols")):
            return [int(v["rows"]), int(v["cols"])]
        return None
    if isinstance(v, (str, bytes)):
        s = v.decode() if isinstance(v, bytes) else v
        s = s.strip().lstrip("[(").rstrip("])")
        parts = s.replace("x", ",").split(",")
        if all(p.strip().isdigit() for p in parts):
            return [int(p) for p in parts]
    return None


def probe_int(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return int(v) if v == int(v) else None
    if isinstance(v, (str, bytes)):
        s = v.decode() if isinstance(v, bytes) else v
        s = s.strip()
        if s.isdigit():
            return int(s)
        # 十六进制 0x / 10进制 都试
        try:
            return int(s, 0)
        except ValueError:
            pass
    return None


def probe_dtype_bytes(v):
    if isinstance(v, (str, bytes)):
        s = (v.decode() if isinstance(v, bytes) else v).strip().lower()
        return DTYPE_BYTES.get(s)
    if isinstance(v, dict):
        for k in DTYPE_KEYS:
            if k in v:
                return probe_dtype_bytes(v[k])
    return None


def classify(name):
    n = name.lower()
    if "embed" in n or "tok_emb" in n or "lm_head" in n or "output.weight" in n:
        return "embed"
    if "kv_a_proj_with_mqa" in n or "q_a_proj" in n or "q_b_proj" in n or "kv_b_proj" in n:
        return "mla"          # v2 Gated-MLA
    if "self_attn" in n or "attn" in n:
        return "kda"          # v1 delta/KDA
    if "gate" in n or "router" in n or "e_score" in n:
        return "router"
    if "expert" in n or "moe" in n or "mlp" in n or "ffn" in n:
        return "moe/mlp"
    if "norm" in n or "layernorm" in n or "rms" in n:
        return "norm"
    return "other"


def layer_of(name):
    """从 '...layers.7....' 抽出 7；没有则 None。"""
    import re
    m = re.search(r"layers[._](\d+)", name)
    return int(m.group(1)) if m else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trunk-json", required=True)
    ap.add_argument("--trunk-bin")
    ap.add_argument("--embed-json")
    ap.add_argument("--sample", type=int, default=4,
                    help="每个类别打印前 N 个条目")
    args = ap.parse_args()

    if not os.path.exists(args.trunk_json):
        sys.exit(f"trunk.json 不存在: {args.trunk_json}")

    print(f"== trunk.json: {args.trunk_json}  ({os.path.getsize(args.trunk_json)/1e6:.1f} MB)")
    with open(args.trunk_json, "rb") as f:
        data = json.load(f)

    # —— 顶层结构探测 ——
    top = "dict" if isinstance(data, dict) else f"list(len={len(data)})"
    print(f"顶层类型: {top}")

    # 收集"条目"：dict → 值条目；list → 元素
    # 兼容真实 trunk.json 的三种结构:
    #   A. 顶层 {tensor_name: meta}                  (safetensors 索引)
    #   B. 顶层 {layers:[{tensors:{tensor_name: meta}}]}   (本项目 trunk.json)
    #   C. 顶层 [ {tensor_name: meta} | {name, meta...} ] (分片索引列表)
    entries = []          # (name, meta_dict)

    def flatten_layers(layers):
        out = []
        for e in layers:
            if not isinstance(e, dict):
                continue
            tens = e.get("tensors") if isinstance(e.get("tensors"), dict) else e
            if not isinstance(tens, dict):
                continue
            for k, v in tens.items():
                if isinstance(v, dict):
                    out.append((k, v))
                else:
                    out.append((k, {}))
        return out

    if isinstance(data, dict):
        if isinstance(data.get("layers"), list) and "tensors" in (
                data["layers"][0] if data["layers"] and isinstance(data["layers"][0], dict) else {}):
            # 结构 B: trunk.json
            entries = flatten_layers(data["layers"])
        else:
            for k, v in data.items():
                if k == "__metadata__" or k.startswith("_"):
                    continue
                # v 可能是 meta dict、或直接是 shape list、或 {"shape":..., ...}
                if isinstance(v, dict):
                    entries.append((k, v))
                else:
                    entries.append((k, {}))
    elif isinstance(data, list):
        # 结构 C: 可能是 [ {"layers":...} ] 或直接分片；先探测
        first = data[0] if data else None
        if isinstance(first, dict) and isinstance(first.get("layers"), list):
            entries = flatten_layers(first["layers"])
        else:
            for e in data:
                if not isinstance(e, dict):
                    continue
                name = None
                meta = {}
                for k, v in e.items():
                    if k in NAME_KEYS and isinstance(v, (str,)):
                        name = v
                    else:
                        meta[k] = v
                entries.append((name or f"<list-entry>", meta))

    print(f"识别到张量条目: {len(entries)}")

    # —— 逐条目解析字段 ——
    resolved = []
    bad = 0
    for name, meta in entries:
        shape = None
        for k in SHAPE_KEYS:
            shape = probe_shape(meta.get(k))
            if shape:
                break
        off = None
        for k in OFFSET_KEYS:
            if k in meta:
                off = probe_int(meta[k])
                if off is not None:
                    break
        size = None
        for k in SIZE_KEYS:
            if k in meta:
                size = probe_int(meta[k])
                if size is not None:
                    break
        dbytes = probe_dtype_bytes(meta)
        elems = 1
        for s in (shape or []):
            elems *= s
        expect = elems * (dbytes or 0)
        resolved.append({
            "name": name, "shape": shape, "offset": off, "size": size,
            "dbytes": dbytes, "expect": expect,
            "cat": classify(name), "layer": layer_of(name),
        })
        if (shape is None) or (off is None and size is None) or (dbytes is None):
            bad += 1

    print(f"解析完全成功: {len(resolved)-bad}/{len(resolved)}  "
          f"(shape缺:{sum(1 for r in resolved if r['shape'] is None)}, "
          f"offset/size缺:{sum(1 for r in resolved if r['offset'] is None and r['size'] is None)}, "
          f"dtype缺:{sum(1 for r in resolved if r['dbytes'] is None)})")

    # —— dtype 分布 ——
    from collections import Counter
    dt = Counter(r["dbytes"] for r in resolved)
    print("dtype(字节/元素)分布:", dict(dt))

    # —— 类别/层统计 ——
    cats = Counter(r["cat"] for r in resolved)
    print("类别计数:", dict(cats))
    lyr = Counter(r["layer"] for r in resolved if r["layer"] is not None)
    if lyr:
        nmax, nmn = max(lyr), min(lyr)
        print(f"层序号范围: [{nmn}, {nmax}]  (gaps: "
              f"{[i for i in range(nmn, nmax+1) if i not in lyr]})")

    # —— 代表张量样例 ——
    def show(cat, sample=None, layer=None):
        rows = [r for r in resolved if r["cat"] == cat]
        if layer is not None:
            rows = [r for r in rows if r["layer"] == layer]
        rows = rows[:sample or args.sample]
        for r in rows:
            shp = r["shape"] or "?"
            sz = r["size"] or "?"
            of = r["offset"] or "?"
            ex = r["expect"] or "?"
            nm = r["name"] if len(r["name"]) < 60 else r["name"][:57] + "..."
            print(f"   {nm:<60} shape={shp} off={of} size={sz} expected(shape*dtype)={ex}")

    print("\n-- KDA(v1) 代表层 (sample) --")
    c1 = [r for r in resolved if r["cat"] == "kda"]
    if c1:
        L = c1[0]["layer"]
        print(f"   (取 layer={L})")
        show("kda", layer=L)
    else:
        show("kda")
    print("\n-- MLA(v2) 代表层 (sample) --")
    c2 = [r for r in resolved if r["cat"] == "mla"]
    if c2:
        L = c2[0]["layer"]
        print(f"   (取 layer={L})")
        show("mla", layer=L)
    else:
        show("mla")
    print("\n-- router (sample) --")
    show("router")
    print("\n-- embed (sample) --")
    show("embed")
    print("\n-- moe/mlp (sample) --")
    show("moe/mlp")

    # —— 越界检查（如果给了 trunk.bin） ——
    if args.trunk_bin and os.path.exists(args.trunk_bin):
        bsz = os.path.getsize(args.trunk_bin)
        print(f"\ntrunk.bin 大小: {bsz/1e9:.3f} GB")
        oob = [r for r in resolved if r["offset"] is not None
               and r["offset"] is not None and r["offset"] >= bsz]
        print(f"offset 越界条目: {len(oob)}  {oob[:5] if oob else ''}")
        # 抽查: 某条目 offset 处前 4 字节
        probe = [r for r in resolved if r["offset"] is not None and r["size"]]
        if probe:
            r = probe[len(probe)//2]
            try:
                with open(args.trunk_bin, "rb") as f:
                    f.seek(r["offset"])
                    head = f.read(min(16, r["size"] or 16))
                print(f"抽查 [{r['name'][:40]}] offset={r['offset']} 头16B: {head.hex()}")
            except Exception as e:
                print(f"抽查失败: {e}")

    # —— embed 分片 ——
    if args.embed_json:
        if os.path.exists(args.embed_json):
            with open(args.embed_json) as f:
                ei = json.load(f)
            print(f"\nembed index 顶层 keys 前8: {list(ei)[:8]}")
            wm = ei.get("weight_map") or {}
            print(f"embed weight_map 张量数: {len(wm)}")
            for k in list(wm)[:6]:
                print(f"   {k} -> {wm[k]}")

    # —— 输出 resolved schema 摘要（forward 探针复用） ——
    print("\n== resolved schema 摘要（可能字段组合） ==")
    if resolved:
        r = resolved[0]
        print("  字段: name / shape / offset / size / dbytes / cat / layer")
    print("完成。")


if __name__ == "__main__":
    main()