#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""perlayer_compress_study.py - 逐层独立压缩潜力分析 (per-layer)

针对 trunk2layers.py 切出的 layer_XXX.bin 每个切片独立统计:
  - MXFP8_E8M7_128 码字熵 (幅值 7-bit / 字节 8-bit)
  - 层内 Huffman (blk=4096+4B/offset) 与全层单码表 Huffman
  - 层内 zlib 实际压缩比 (level 9)
对每层输出独立压缩比 → 板子按层流式取数时, 每层各自解压即可。

输出大小对比:
  original (层切片) | huff(块) | zlib(层单段) | 相对原切片 save%
用法:
  python3 tools/perlayer_compress_study.py <layers_dir> <trunk_layers.json>
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

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("layers_dir")
    ap.add_argument("layers_json")
    ap.add_argument("--limit", type=int, default=93, help="只测前 N 层")
    ap.add_argument("--zlevel", type=int, default=1, help="zlib 压缩级别 (1 快, 9 最高比)")
    a = ap.parse_args()

    man = json.load(open(a.layers_json))
    layers = man["layers"][:a.limit]

    total_orig = total_huff = total_z = 0
    print("%-8s %-8s %12s %9s %9s %9s %9s %9s" %
          ("layer", "kind", "layer_B", "mag.Ent", "byte.Ent", "huff_B", "zlib_B", "z_save%"))
    for lay in layers:
        li = lay["layer"]
        fn = "%s/layer_%03d.bin" % (a.layers_dir, li)
        raw = open(fn, "rb").read()
        nb = len(raw)
        total_orig += nb
        # 提取码字层 (MXFP8 codes): 按张量推进
        with open(fn, "rb") as fb:
            codes_frag = []
            for name, t in sorted(lay["tensors"].items(), key=lambda kv: kv[1]["off"]):
                if t.get("dtype") != "MXFP8_E8M7_128":
                    continue
                rows, cols = int(t["shape"][0]), int(t["shape"][1])
                ngrp = int(t["ngrp"])
                stride = ngrp + cols
                fb.seek(int(t["off"]))
                data = np.frombuffer(fb.read(int(t["nbytes"])), np.uint8)
                data = data.reshape(rows, stride)
                codes_frag.append(data[:, ngrp:].ravel())
        codes = np.concatenate(codes_frag) if codes_frag else np.zeros(0, np.uint8)
        ne = codes.size
        mag_e = entropy_hist(codes & 0x7F, 128) if ne else 0.0
        byte_e = entropy_hist(codes, 256) if ne else 0.0
        # 块 Huffman
        blk = 4096
        nblk = math.ceil(ne / blk)
        hbits = 0
        for k in range(nblk):
            hbits += huffman_len(codes[k*blk:(k+1)*blk])
        hbytes = math.ceil(hbits / 8) + 4 * nblk
        # 单层 zlib: 压"整个层文件" (含 scales + codes), 板侧解压单层流最简
        zbytes = len(zlib.compress(raw, a.zlevel))
        total_huff += hbytes
        total_z += zbytes
        zsave = 100 * (1 - zbytes / nb) if nb else 0.0
        print("%6d %-8s %12d %9.2f %9.2f %9d %9d %8.1f" %
              (li, "v1/KDA" if lay["layer"] not in {i for i in range(3,92,4)}|{92} else "v2/MLA",
               nb, mag_e, byte_e, hbytes, zbytes, zsave))
    print("-" * 84)
    print("总计: orig %d (%.2f GB) | huff %d (%.2f GB, %6.1f%%) | zlib %d (%.2f GB, %6.1f%%)"
          % (total_orig, total_orig/2**30, total_huff, total_huff/2**30,
             100*(1-total_huff/total_orig),
             total_z, total_z/2**30, 100*(1-total_z/total_orig)))

if __name__ == "__main__":
    main()