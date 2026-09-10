#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""trunk2layers.py - 把 MXFP8 trunk 按 93 层切成独立切片文件

背景 (board-1g-k3-frozen.md §9 待办1):
  板子(1GB DDR3)按层流式取数 —— 每 token 逐层拉"当前层切片 + 本层 top16 专家",
  用完即弃。因此需要把 56.6GB 的 trunk.bin 拆成 93 个独立切片文件,
  供板子逐层随机读, 避免一次读整个 56.6GB。

输出:
  <dst>/layer_000.bin .. layer_092.bin   每层独立切片(含尾部 align 填充)
  <dst>/trunk_layers.json                 逐层清单(与 trunk.json 同构,
                                           file_off 为层内偏移, 含路由头→专家实体说明)
  <dst>/sizes.tsv                          层号 | 类型(v1/v2) | nbytes | GiB | 切片文件

用法:
  python3 tools/trunk2layers.py /mnt/nvme/trunk_p128t_full <dst_dir>
"""
import argparse, json, os, sys

# v1(KDA) / v2(Gated-MLA) 层号划分, 与 board-1g-k3-frozen.md §2 一致
# v2 层号: 93 层固定花纹 = 23x(v1 v1 v1 v2) + 末层 v2(92) → v2 = {3,7,11,...,91,92}
V2_LAYERS = {i for i in range(3, 92, 4)} | {92}
V1_LAYERS = set(range(93)) - V2_LAYERS

ALIGN = 4096


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src_dir", help="trunk 目录 (含 trunk.bin + trunk.json)")
    ap.add_argument("dst_dir", help="输出切片目录")
    ap.add_argument("--dry", action="store_true", help="只测逐层字节不切文件")
    args = ap.parse_args()

    man = json.load(open(os.path.join(args.src_dir, "trunk.json")))
    layers = man["layers"]
    assert man["n_layers"] == 93, "expected 93 layers, got %d" % man["n_layers"]

    if not args.dry:
        os.makedirs(args.dst_dir, exist_ok=True)

    src = open(os.path.join(args.src_dir, "trunk.bin"), "rb")
    rows = []
    total = 0
    for lay in layers:
        li = lay["layer"]
        base = int(lay["file_off"])
        nb = int(lay["nbytes"])
        total += nb
        is_v1 = li in V1_LAYERS
        kind = "v1/KDA" if is_v1 else "v2/MLA"
        # 校验: 层内 tensors 覆盖 [0, nbytes) 且不重叠
        tensors = lay["tensors"]
        segs = sorted(((int(t["off"]), int(t["nbytes"]), n) for n, t in tensors.items()))
        covered = 0
        gap = []
        for off, sz, nm in segs:
            if off > covered:
                gap.append((covered, off))
            covered = max(covered, off + sz)
        pad = nb - covered
        if not args.dry:
            src.seek(base)
            data = src.read(nb)
            fn = os.path.join(args.dst_dir, "layer_%03d.bin" % li)
            with open(fn, "wb") as f:
                f.write(data)
        rows.append((li, kind, nb, nb / 2**30, len(segs), len(gap), pad))
        print("  layer %3d %-7s %10d B %8.3f GiB  tensors=%3d gaps=%d pad=%d"
              % (li, kind, nb, nb / 2**30, len(segs), len(gap), pad), flush=True)
    src.close()

    # 汇总 + 核 632/419 口径
    v1_tot = sum(r[2] for r in rows if r[1] == "v1/KDA")
    v2_tot = sum(r[2] for r in rows if r[1] == "v2/MLA")
    nv1 = sum(1 for r in rows if r[1] == "v1/KDA")
    nv2 = sum(1 for r in rows if r[1] == "v2/MLA")
    print("\n=== 汇总 ===")
    print("  总字节: %d (= trunk.bin %d, diff %d)" % (total, os.path.getsize(os.path.join(args.src_dir, "trunk.bin")), os.path.getsize(os.path.join(args.src_dir, "trunk.bin")) - total))
    print("  v1/KDA: %d 层 × 平均 %.2f MB → 合计 %.2f GB" % (nv1, v1_tot / nv1 / 2**20, v1_tot / 2**30))
    print("  v2/MLA: %d 层 × 平均 %.2f MB → 合计 %.2f GB" % (nv2, v2_tot / nv2 / 2**20, v2_tot / 2**30))
    print("  board-1g 口径核对: v1 632MB / v2 419MB(外推)")
    print("  实测: v1 %.1f MB / v2 %.1f MB  (层0 含 dense MLP 2.3GB 除外)" % (
        sum(r[2] for r in rows if r[1] == "v1/KDA" and r[0] != 0) / (nv1 - 1) / 2**20,
        v2_tot / nv2 / 2**20))

    if not args.dry:
        out = {
            "src": args.src_dir,
            "align": man.get("align", ALIGN),
            "n_layers": 93,
            "note": "per-layer slices of MXFP8 trunk; each layer_XXX.bin is file_off..+nbytes of trunk.bin (align-padded at tail)",
            "v1_632MB_estimate_note": "board-1g frozen口径, 逐层实测见 sizes.tsv",
            "layers": layers,
        }
        with open(os.path.join(args.dst_dir, "trunk_layers.json"), "w") as f:
            json.dump(out, f)
        with open(os.path.join(args.dst_dir, "sizes.tsv"), "w") as f:
            f.write("layer\tkind\tnbytes\tGiB\tn_tensors\tn_gaps\tpad\n")
            for r in rows:
                f.write("\t".join(map(str, r)) + "\n")
        print("\n已写出 %d 个切片 + trunk_layers.json + sizes.tsv 到 %s"
              % (len(rows), args.dst_dir))


if __name__ == "__main__":
    main()