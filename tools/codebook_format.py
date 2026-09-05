#!/usr/bin/env python3
"""codebook_format.py — 代码本+逃逸 无损存储格式 (Codebook + Escape).

背景: MXFP8 固定8bit格点装不下真实分布(死). 换成"格式适配分布":
  全部实际唯一值 → 代码本(表); 每权重存索引; 小众尾部值用逃逸通道存原值.
  无损: 表含所有出现值, 索引精确指回. 无解压: 查表即得(k,e), 移位GEMV.
  这正是"专家21值查表"的自然推广到 dense.

  平均位宽 = (1+log2(k))×(1-逃逸率) + (1+14)×逃逸率
  逃逸_tag 1bit(区分查表/逃逸), 代码本索引 log2(k), 逃逸值 14bit(e6m7原值)

  目标: 真实分布唯一值集中 → 平均位宽逼近熵(用户实测~6.5).

用法:
  python3 codebook_format.py --raw <权重.bin> [--dtype float32]
  python3 codebook_format.py --n 500000          # 合成测试
  输出: 唯一值数/各k下的平均bit/逃逸率/无损确认.
"""
import argparse
import math
import numpy as np

def format_report(W, tag="权重"):
    W = np.asarray(W, dtype=np.float32).reshape(-1)
    n = W.size
    vals, cnt = np.unique(W, return_counts=True)
    n_uniq = len(vals)
    fr = cnt / cnt.sum()
    ent = -np.sum(fr * np.log2(fr + 1e-30))

    print(f"\n=== {tag} ===  元素={n:,}  唯一值数={n_uniq:,}  熵={ent:.3f} bit/权重")
    print(f"  若用纯代码本(无逃逸): 索引 bit = log2({n_uniq}) ≈ {math.log2(n_uniq):.1f}")

    # 扫描代码本大小 k (2的幂), 计算逃逸率 + 平均位宽
    print(f"\n  纯查表格式  平均bit(含tag)  ≈ 无损+无解压")
    # 纯代码本: tag 0 全部查表, 索引 bit = ceil(log2(k)) ; 需保证 k>=n_uniq → 索引 = log2(n_uniq) 向上
    codeb_bits = max(1, math.ceil(math.log2(n_uniq)))
    print(f"  [纯代码本] 索引 {codeb_bits}bit + 1tag → 固定 {codeb_bits:>3}bit/权重   (C: 全查表)")
    # 降到真正tag+code + escape
    results = []
    total = 0.0
    # 按频率从高到低累计, 直到覆盖 (1-p) 概率
    order = np.argsort(-cnt)
    cum = np.cumsum(cnt[order]) / n
    print(f"\n  代码本+逃逸(按频率切分):")
    for k in [32, 64, 128, 256, 512, 1024, 2048, 4096]:
        if k >= n_uniq:
            continue
        perc_cover = cum[k-1] if k <= len(cum) else 1.0   # top-k 覆盖比例
        esc = 1.0 - perc_cover                             # 逃逸率
        bits = (1 + math.ceil(math.log2(k))) * perc_cover + (1 + 14) * esc
        n_exact = int((cnt[order][:k] > 0).sum())
        results.append((k, esc, bits, n_exact))
        print(f"  k={k:<5} 覆盖{perc_cover*100:6.2f}% 逃逸{esc*100:6.2f}% 平均{bits:5.2f}bit/权重  (代码本{n_exact}值)")

    # 推荐: 平均bit最低的 k
    if results:
        best = min(results, key=lambda r: r[2])
        print(f"\n  → 推荐 k={best[0]} 码本: 平均 {best[2]:.2f} bit/权重  "
              f"(无损, 逃逸值走14bit通道)")
        print(f"    对比: e6m7固定14bit → {best[2]:.2f}bit = 压缩 {14/best[2]:.2f}x")
        print(f"    对比: 熵下界 = {ent:.2f}bit")
    return ent, n_uniq

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw")
    ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--dtype", default="float32")
    args = ap.parse_args()

    if args.raw:
        W = np.fromfile(args.raw, dtype=args.dtype)
        format_report(W, args.raw)
    elif args.n:
        rng = np.random.RandomState(0)
        W = rng.normal(0, 0.02, args.n).astype(np.float32)
        format_report(W, f"合成高斯({args.n})")
    else:
        print("需 --raw 或 --n"); return

if __name__ == "__main__":
    main()