#!/usr/bin/env python3
"""probe_real_weights.py — 对真实模型权重(safetensors/裸bin)做三要素探针。

三要素(判定权重可"公式化"压缩/移位计算的通用判据, 与格式无关):
  1. 唯一值数 k vs 元素数 n  →  k<<n 则可用 log2(k) 位索引无损查表
  2. 二幂结构 (k·2^e, k奇整数) 比例 → 高则乘法=移位, 免解压直接GEMV
  3. 奇异值谱形态 → 低秩则 SVD/低秩压缩可行, 满秩则不可

用法:
  A. 读 safetensors 张量:
       python3 probe_real_weights.py --safetensors <file> --tensor <name>
  B. 读裸 fp32 bin(mxfp4 fixture 类似):
       python3 probe_real_weights.py --raw <bin> --dtype float32 --shape 64,3584
"""
import argparse
import math
import numpy as np

def analyze(W, name):
    n = W.size
    print(f"\n=== {name}: shape={list(W.shape)} 元素={n:,} "
          f"fp32等价={W.nbytes/1e6:.1f}MB dtype={W.dtype}")
    vals, u = np.unique(W, return_counts=True)
    print(f"[1] 唯一值数: {len(vals):,}  ({len(vals)/n*100:.3f}%)")
    if len(vals) < n:
        print(f"    → 每元素仅需 log2({len(vals)})={np.ceil(np.log2(len(vals))):.0f} 位索引, "
              f"压缩比 {32/max(1,np.ceil(np.log2(len(vals)))):.2f}x 无损查表")
    print(f"    范围 [{W.min():.4f},{W.max():.4f}]  mean={W.mean():.5f} std={W.std():.5f}")

    nz = vals[vals != 0]
    ok = int((vals == 0).sum())
    for v in nz[:4000]:
        av = abs(v)
        for kk in [1, 3, 5, 7, 9]:
            for ee in range(-24, 8):
                if abs(av - kk * (2.0 ** ee)) < 1e-6 * max(1.0, abs(av)):
                    ok += 1
                    break
            else:
                continue
            break
    print(f"[2] 二幂(k·2^e)比例(采样4000唯一值): {ok/max(1,len(vals))*100:.1f}%")

    # 谱分析 + 有效秩 + 近无损低秩代表位宽 b/w
    try:
        M = W.reshape(W.shape[0], -1)
        M = M[: min(60000, M.shape[0]), :]          # 内存保护,降采样行
        S = np.linalg.svd(M, compute_uv=False)
        ncol = min(M.shape)
        if S.size > 1:
            e2 = S ** 2
            total = e2.sum()
            def cum_rank(frac):
                csum = np.cumsum(e2) / total
                return int(np.searchsorted(csum, frac) + 1)
            r95 = cum_rank(0.95)                     # 95%能量所需秩
            r99 = cum_rank(0.99)
            rank_ratio = r95 / ncol                  # 有效秩占比
            # 低秩代表位宽: 用 r 个奇异值(每个 fp32=32b) + 正奇向量(每元素独立)
            # 近似: 存 U[:,:r] (nrow*r) + S[:r] + V[:,:r] (ncol*r), 都在 fp32
            # 但元素数是本源全量 fp32 的分子;
            # 实际存储 = (nrow+ncol)*r + r 个奇异值, 除以总元素数 n
            for r, tag in [(r95, "95%能量"), (r99, "99%能量")]:
                wt = r * (M.shape[0] + M.shape[1] + 1)
                bperw = 32.0 * wt / n if wt < n else 32.0 * n / n
                print(f"    low-rank[{tag}] 秩r={r} 有效秩占比={r/M.shape[1]*100:.1f}% "
                      f"→ 若只存{tag}约需 {bperw:.2f} b/w (fp32全量=32, fp16=16)")
            span = S[0] / S[-1] if S[-1] > 0 else float('inf')
            print(f"[3] 谱: max={S[0]:.4f} min={S[-1]:.4f} span={span:.1f} "
                  f"前10能量={e2[:10].sum()/total*100:.1f}% "
                  f"有效秩占比(95%能量)={rank_ratio*100:.1f}%")
        else:
            print("[3] 谱: 一维, 无法SVD")
    except Exception as e:
        print(f"[3] 谱/SVD失败: {e}")

def read_bf16_as_f32(f, n):
    raw = f.read(n * 2)
    b = np.frombuffer(raw, dtype=np.uint16)
    w = (b.astype(np.uint32) << 16).astype(np.uint32)
    return w.view(np.float32)

def from_safetensors(path, tnames):
    import json
    tensors = {}
    with open(path, "rb") as f:
        n = int.from_bytes(f.read(8), "little")
        hdr = json.loads(f.read(n))
        start = 8 + n
        for name in tnames:
            v = hdr[name]
            o0, o1 = v["data_offsets"]
            shape = v["shape"]
            nn = int(np.prod(shape))
            f.seek(start + o0)
            if v["dtype"] == "BF16":
                W = read_bf16_as_f32(f, nn).reshape(shape)
            elif v["dtype"] == "F32":
                W = np.frombuffer(f.read(4 * nn), dtype=np.float32).reshape(shape)
            else:
                raise ValueError(f"未支持 dtype {v['dtype']}")
            tensors[name] = W
            analyze(W, name)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--safetensors", help="safetensors 文件路径")
    ap.add_argument("--tensor", action="append", help="要分析的张量名(可多个)")
    ap.add_argument("--raw", help="裸权重 bin 路径")
    ap.add_argument("--dtype", default="float32")
    ap.add_argument("--shape", help="如 64,3584")
    args = ap.parse_args()

    if args.safetensors:
        names = args.tensor if args.tensor else []
        if not names:
            import json
            with open(args.safetensors, "rb") as f:
                n = int.from_bytes(f.read(8), "little")
                names = [k for k in json.loads(f.read(n)) if k != "__metadata__"]
        from_safetensors(args.safetensors, names)
    elif args.raw:
        W = np.fromfile(args.raw, dtype=args.dtype)
        if args.shape:
            W = W.reshape(tuple(int(x) for x in args.shape.split(",")))
        analyze(W, args.raw)
    else:
        ap.print_help()

if __name__ == "__main__":
    main()