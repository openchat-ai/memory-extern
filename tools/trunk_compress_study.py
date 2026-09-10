#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""trunk_compress_study.py - MXFP8 trunk 全 93 层压缩潜力分析

对 trunk_p128t_full/trunk.bin 的每个 MXFP8_E8M7_128 张量, 逐层统计:
  - 7-bit 幅值熵 / 8-bit 码字熵
  - 块 Huffman (blk=4096 + 4B/block) 可达 bits/elem
聚合到张量类型, 给出:
  - 当前 8.0625 bit/elem (8bit code + 8/128 scale) vs Huffman 下限
  - 全 trunk 理论无损压缩潜力 (GB 级)
  - 有损选项 (MXFP4 / 更低 bit) 的定性边界

用法: python3 tools/trunk_compress_study.py <trunk_dir> [--layers 全部]
"""
import argparse, json, math, heapq, zlib
import numpy as np

def entropy_hist(b, maxv):
    c = np.bincount(b.astype(np.uint64), minlength=maxv)
    c = c[c > 0].astype(np.float64)
    p = c / c.sum()
    return float(-(p * np.log2(p)).sum())

def huffman_len(code):
    c = np.bincount(code.astype(np.uint64), minlength=256)
    nz = c[c > 0]
    if nz.size <= 1:
        return int(nz.sum())
    class Node:
        __slots__ = ("cnt", "l", "r")
        def __init__(s, cnt, l=None, r=None):
            s.cnt, s.l, s.r = cnt, l, r
        def __lt__(s, o): return s.cnt < o.cnt
    pq = [(int(c), i, Node(int(c))) for i, c in enumerate(nz)]
    heapq.heapify(pq)
    while len(pq) > 1:
        (c1, _, n1) = heapq.heappop(pq); (c2, _, n2) = heapq.heappop(pq)
        heapq.heappush(pq, (c1 + c2, -1, Node(c1 + c2, n1, n2)))
    total = 0
    def walk(nd, d):
        nonlocal total
        if nd.l is None and nd.r is None:
            total += d * nd.cnt
        else:
            if nd.l: walk(nd.l, d + 1)
            if nd.r: walk(nd.r, d + 1)
    _, _, root = pq[0]
    walk(root, 0)
    return total

CUR_BPE = 8.0 + 8.0 / 128.0   # 当前 per-128 布局

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trunk_dir")
    ap.add_argument("--layers", default="all")
    a = ap.parse_args()

    man = json.load(open(a.trunk_dir + "/trunk.json"))
    layers = man["layers"]
    if a.layers != "all":
        want = [int(x) for x in a.layers.split(",")]
        layers = [l for l in layers if l["layer"] in want]

    agg = {}   # tensor_type -> [nelems, huff_bits, zlib_bits]
    total_ne = 0
    total_cur = 0
    total_hbits = 0
    with open(a.trunk_dir + "/trunk.bin", "rb") as mb:
        for lay in layers:
            L = lay["layer"]
            base = int(lay["file_off"])
            for name, t in sorted(lay["tensors"].items(), key=lambda kv: kv[1]["off"]):
                if t.get("dtype") != "MXFP8_E8M7_128":
                    continue
                rows, cols = int(t["shape"][0]), int(t["shape"][1])
                ngrp = int(t["ngrp"])
                stride = ngrp + cols
                mb.seek(base + int(t["off"]))
                data = np.frombuffer(mb.read(int(t["nbytes"])), np.uint8)
                data = data.reshape(rows, stride)
                codes = data[:, ngrp:].ravel()
                ne = codes.size
                blk = 4096
                nb = math.ceil(ne / blk)
                hb = zb = 0
                for k in range(nb):
                    s = codes[k*blk:(k+1)*blk]
                    hb += huffman_len(s)
                    zb += len(zlib.compress(s.tobytes(), 9)) * 8
                hbytes = math.ceil(hb / 8) + 4 * nb
                zbytes = math.ceil(zb / 8) + 4 * nb
                sn = name.rsplit(".", 2)[-2] + "." + name.rsplit(".", 1)[-1]
                e = agg.setdefault(sn, [0, 0, 0])
                e[0] += ne
                e[1] += hbytes * 8
                e[2] += zbytes * 8
                total_ne += ne
                total_cur += ne * CUR_BPE
                total_hbits += hbytes * 8
    print("=== 全 %d 层压缩潜力 (%d MXFP8 张量类型) ===" % (len(layers), len(agg)))
    print("%-46s %14s %10s %10s" % ("tensor", "elems", "huff bit/e", "save%"))
    print("-" * 84)
    for sn, (ne, hbits, zbits) in sorted(agg.items(), key=lambda kv: -kv[1][0]):
        hpe = hbits / ne + 8.0 / 128.0
        zpe = zbits / ne + 8.0 / 128.0
        print("%-46s %14d %9.2f %9.1f  (zlib %.2f, save %.1f%%)"
              % (sn, ne, hpe, 100 * (CUR_BPE - hpe) / CUR_BPE,
                 zpe, 100 * (CUR_BPE - zpe) / CUR_BPE))
    print("-" * 84)
    tot_hpe = total_hbits / total_ne + 8.0 / 128.0
    print("当前存储 : %10.3f bit/elem → 全 trunk %.2f GB" % (CUR_BPE, total_cur / 8 / 2**30))
    print("Huffman  : %10.3f bit/elem → 全 trunk %.2f GB (无损, 省 %.2f GB = %.1f%%)"
          % (tot_hpe, tot_hpe * total_ne / 8 / 2**30,
             (CUR_BPE - tot_hpe) * total_ne / 8 / 2**30,
             100 * (CUR_BPE - tot_hpe) / CUR_BPE))
    print("注意: Huffman 需块级解压, 板子按层流式取数时引入逐块解码延迟;")
    print("      HANDOFF 明确放弃位打包省 bit, 因引回解压。上表为无损理论上限。")

if __name__ == "__main__":
    main()