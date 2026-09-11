#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""slices_manifest.py - 从拆片输出的 trunk_layers.json 生成切片级清单 trunk_slices.json

背景:
  trunk2layers.py 输出的 trunk_layers.json 里, 层级 file_off 指回原始的 53GB trunk.bin
  (已被删除)。切片文件 layer_000.bin..layer_092.bin 已成为独立真源。
  本工具把清单"反转"成切片视角:
    - 每层给出切片文件名 (layer_XXX.bin) + 类型 (v1/v2) + 文件字节数;
    - 张量 off 语义 = 切片文件内字节偏移 (原本就是层内相对偏移, 无需改动);
    - 层级 file_off 废弃, 由 file 字段取代。

用法:
  python3 tools/slices_manifest.py /mnt/nvme/trunk_layers_out/trunk_layers.json [<dst.json>]
"""
import argparse, json, os

V2_LAYERS = {i for i in range(3, 92, 4)} | {92}
V1_LAYERS = set(range(93)) - V2_LAYERS
KIND = {True: "v1/KDA", False: "v2/MLA"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src_json", help="trunk_layers.json (拆片输出)")
    ap.add_argument("dst_json", nargs="?", default="trunk_slices.json",
                    help="输出路径 (默认 ./trunk_slices.json)")
    args = ap.parse_args()

    man = json.load(open(args.src_json))
    out = {
        "format": "trunk_slices/1",
        "note": "per-layer slice manifest; tensor off = byte offset within the layer's own slice file layer_XXX.bin; "
                "older layer-level file_off referenced the deleted whole-trunk binary and is superseded by 'file'",
        "n_layers": man["n_layers"],
        "v1_count": 0,
        "v2_count": 0,
        "slices": [],
    }
    for lay in man["layers"]:
        li = int(lay["layer"])
        is_v1 = li in V1_LAYERS
        kind = KIND[is_v1]
        if is_v1:
            out["v1_count"] += 1
        else:
            out["v2_count"] += 1
        out["slices"].append({
            "layer": li,
            "kind": kind,
            "file": "layer_%03d.bin" % li,
            "nbytes": int(lay["nbytes"]),
            "n_tensors": len(lay["tensors"]),
            "shard": lay.get("shard"),
            "tensors": lay["tensors"],
        })

    with open(args.dst_json, "w") as f:
        json.dump(out, f, indent=1)
    print("wrote %s: %d slices (v1=%d v2=%d), total %d B"
          % (args.dst_json, len(out["slices"]), out["v1_count"], out["v2_count"],
             sum(s["nbytes"] for s in out["slices"])))


if __name__ == "__main__":
    main()