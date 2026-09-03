#!/usr/bin/env python3
"""slice_k3_micro.py — 从完整官方 K3 权重切出最小可测切片 (自用, 桌面运行)。

在桌面的完整 K3 safetensors 上跑, 只提取少量张量成独立小包, 用于:
  1) 三要素探针(唯一值/二幂/谱)  2) 数值低秩重构误差
产出几百 MB 的测试切片, 免去反复下载大模型。

用法:
  python3 slice_k3_micro.py --k3 <dir-of-model-*.safetensors 或单分片> --out <out_dir>
    [--layers 0,1]         要切的层 (默认只切第0层, 节省)
    [--experts 4]          每层取几个 routed expert (默认4)
    [--include-shared-expert]  是否含共享专家
    [--as-npy]             另存 .npy (probe 直接读)

输出:
  out_dir/sliced.safetensors  — 小型分片(含 index 元数据可直接 probe)
  out_dir/manifest.json      — 张量清单+来源
  out_dir/*.npy (--as-npy)   — probe_weight/probe_real 直接读的裸权重

依赖: numpy, safetensors (pip install safetensors; 若装不了则退回纯 numpy 解析)
"""
import argparse
import json
import os
import re
import numpy as np

SAFETENSORS_PAT = re.compile(r"model-(\d+)-of-(\d+)\.safetensors")

def load_safetensors_tensor(f, hdr_dict, tname, data_offset):
    """读取单个张量; data_offset 为该分片数据区起始(文件内绝对偏移).

    safetensors 文件布局: 8字节头部长度N + N字节JSON + 数据区.
    头部里 data_offsets 是相对数据区起始的偏移.
    """
    d = hdr_dict[tname]
    o0, o1 = d["data_offsets"]
    shape = d["shape"]
    nn = int(np.prod(shape))
    dt = d["dtype"]
    f.seek(data_offset + o0)
    raw = f.read(o1 - o0)
    if dt == "BF16":
        b = np.frombuffer(raw, dtype=np.uint16)
        w = (b.astype(np.uint32) << 16).astype(np.uint32)
        W = w.view(np.float32)
    elif dt == "F32":
        W = np.frombuffer(raw, dtype=np.float32)
    elif dt == "F16":
        W = np.frombuffer(raw, dtype=np.float16).astype(np.float32)
    elif dt in ("I8", "U8"):
        W = np.frombuffer(raw, dtype=np.int8 if dt == "I8" else np.uint8).astype(np.float32)
    else:
        W = np.frombuffer(raw, dtype=np.float32)
    return W.reshape(shape).copy()

def build_target_tensors(layers, n_experts, include_shared):
    """返回要提取的张量名列表(前缀)."""
    targets = []
    for L in layers:
        a = f"language_model.model.layers.{L}."
        # dense attention (MLA 常见命名; 兼容多种)
        for n in ["self_attn.q_proj", "self_attn.k_proj", "self_attn.v_proj",
                  "self_attn.o_proj", "self_attn.f_a_proj", "self_attn.f_b_proj",
                  "self_attn.g_proj", "self_attn.b_proj", "self_attn.a_proj"]:
            targets.append((a + n + ".weight", "dense/attention"))
        # dense MLP
        for n in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj"]:
            targets.append((a + n + ".weight", "dense/mlp"))
        # routed experts
        for e in range(n_experts):
            targets.append((a + f"mlp.experts.{e}.gate.weight", "expert"))
            targets.append((a + f"mlp.experts.{e}.up.weight", "expert"))
            targets.append((a + f"mlp.experts.{e}.down.weight", "expert"))
        if include_shared:
            for n in ["mlp.shared_expert.gate_proj", "mlp.shared_expert.up_proj",
                      "mlp.shared_expert.down_proj"]:
                targets.append((a + n + ".weight", "expert/shared"))
    return targets

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--k3", required=True, help="完整K3目录(含 model-*.safetensors) 或单个分片路径")
    ap.add_argument("--out", required=True, help="输出目录")
    ap.add_argument("--layers", default="0", help="逗号分隔层号, 默认0")
    ap.add_argument("--experts", type=int, default=4)
    ap.add_argument("--include-shared-expert", action="store_true")
    ap.add_argument("--as-npy", action="store_true")
    args = ap.parse_args()

    layers = [int(x) for x in args.layers.split(",") if x.strip()]
    targets = build_target_tensors(layers, args.experts, args.include_shared_expert)

    # 收集目标分片文件
    k3_dir = args.k3 if os.path.isdir(args.k3) else os.path.dirname(args.k3)
    shards = sorted(
        os.path.join(k3_dir, f) for f in os.listdir(k3_dir)
        if SAFETENSORS_PAT.search(f)
    )
    if not shards:
        shards = [args.k3] if os.path.isfile(args.k3) else []
    if not shards:
        print("! 未找到 model-*.safetensors 分片"); return

    os.makedirs(args.out, exist_ok=True)
    # 分片 -> 张量名索引(用 index.json 若有)
    index_path = os.path.join(k3_dir, "model.safetensors.index.json")
    name2shard = {}
    if os.path.exists(index_path):
        with open(index_path) as f:
            name2shard = json.load(f).get("weight_map", {})

    # 逐张量: 定位读取
    collected = {}  # name -> (np.ndarray, role)
    missing = []
    # 预读各分片 header 一次
    hdrs = {}
    for sh in shards:
        try:
            with open(sh, "rb") as f:
                nb = int.from_bytes(f.read(8), "little")
                hdr = json.loads(f.read(nb))
                hdr["__data_offset__"] = 8 + nb
                hdrs[sh] = hdr
        except Exception:
            pass

    for tname, role in targets:
        # 找所在分片
        sh = name2shard.get(tname)
        found = None
        if sh:
            sh = os.path.join(k3_dir, sh)
            if os.path.exists(sh) and sh in hdrs:
                found = sh
        if not found:
            # 搜索
            for sh2, hdr in hdrs.items():
                if tname in hdr:
                    found = sh2
                    break
        if not found:
            missing.append(tname)
            continue
        try:
            with open(found, "rb") as f:
                W = load_safetensors_tensor(f, hdrs[found], tname,
                                            hdrs[found]["__data_offset__"])
            collected[tname] = (W, role)
        except Exception as ex:
            missing.append(f"{tname} ({ex})")

    print(f"目标张量 {len(targets)}, 成功 {len(collected)}, 缺失 {len(missing)}")
    if missing[:20]:
        print("缺失示例:")
        for m in missing[:20]:
            print("  ", m)

    if not collected:
        print("! 一个都没取到, 检查 --layers 命名 或 index.json."); return

    # 写 manifest
    manifest = {
        "source": os.path.basename(k3_dir.rstrip("/")),
        "layers": layers,
        "experts_per_layer": args.experts,
        "tensors": [
            {"name": n, "role": r, "shape": list(W.shape), "dtype": str(W.dtype)}
            for n, (W, r) in collected.items()
        ],
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)

    # 存 .npy(probe 直接读裸权重)
    if args.as_npy:
        for n, (W, r) in collected.items():
            safe = n.replace(".", "_").replace("/", "_")
            np.save(os.path.join(args.out, f"{safe}.npy"), W)
        print(f"已输出 {len(collected)} 个 .npy 到 {args.out}")

    total_mb = sum(W.nbytes for W, _ in collected.values()) / 1e6
    print(f"切片总大小: {total_mb:.1f} MB")
    print("→ 用 tools/probe_real_weights.py 测每个 .npy:")
    print('   python3 tools/probe_real_weights.py --raw <xxx.npy> --dtype float32')

if __name__ == "__main__":
    main()