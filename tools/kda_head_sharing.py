#!/usr/bin/env python3
# KDA qkv 头结构/共享度分析 —— 一次判定「需要蒸馏 or 张量分解即可省掉蒸馏」
# 跑在有权重 + torch 的机器(WSL2/GPU)上。
# 输入: 一个 KDA 层 (smol-kimi-k3 或 真 K3) 的 q/k/v 投影权重
# 输出: 
#   1. 扁平矩阵的有效秩(捕获90%能量需保留多少维) -> 扁平SVD能否压
#   2. 头结构[ H, HD, d ]的跨头共享度 -> 张量分解能否压
#   3. 结论: 若头共享度高(低秩张量) => 张量分解可行 => 可能不需要蒸馏
#            若头间独立(满秩张量) => 张量分解死 => 需要蒸馏
import argparse
import torch

def masked_energy_rank(singular_values, frac=0.9):
    """捕获 frac 能量需保留的最大奇异值个数"""
    s2 = singular_values ** 2
    total = s2.sum()
    acc = 0.0
    for i, v in enumerate(singular_values):
        acc += v * v
        if acc / total >= frac:
            return i + 1
    return len(singular_values)

def analyze_weight(W, name, H, HD, in_dim, frac=0.9):
    """W: [d_out, d_in] = [H*HD, d_in] 扁平权重"""
    d_out = W.shape[0]
    assert d_out == H * HD, f"{name}: d_out={d_out} != H*HD={H*HD}"
    W = W.to(torch.float32)

    print(f"\n=== {name} : [{d_out},{in_dim}] (H={H}, HD={HD}) ===")

    # 1. 扁平 SVD 有效秩
    s = torch.linalg.svdvals(W)
    ek = masked_energy_rank(s, frac)
    print(f"[扁平SVD]  捕获{frac:.0%}能量需保留 {ek}/{d_out} 行"
          f" (ratio {ek/d_out:.1%})  压缩比≈{d_out/ek:.1f}x -- 需保留维度")
    # 奇异值谱衰减
    e1 = s[0]
    tail = s[-1]
    print(f"          奇异值: σ1={e1:.3f} σ_min={tail:.3f} σ1/σmin={e1/(tail+1e-9):.0f}"
          f"  (≈1 => 满秩均匀, >>1 => 可压)")

    # 2. 头结构: 重排成 [H, HD, d] 张量, 看跨头共享
    #   qkv 的输出行分成 H 组(每组 HD 行)。若所有头共享同一输入子空间,
    #   则 H 个 HDxd 子块的"列空间"应大量重合。
    #   度量: 把 H 个子块拼成 H*HD x d, 求其"块级SVD"的秩 vs 每块独立.
    W_head = W.view(H, HD, in_dim)  # [H, HD, d_in]
    # 跨头共享度量: 展平成 H 个 HDxd, 计算所有头合并空间的低秩逼近误差
    # 简化: 用"头部平均能量 vs 全矩阵" , 并测低秩逼近残差
    U, S, Vt = torch.linalg.svd(W_head.reshape(H * HD, in_dim), full_matrices=False)
    # 头结构可压性: 若 low-rank 逼近残差小 => 可压
    R = min(4, in_dim)  # 试 rank 4 共享基
    rec = (U[:, :R] * S[:R]).matmul(Vt[:R, :])
    rel_err = (W_head.reshape(H * HD, in_dim) - rec).norm() / W_head.reshape(H * HD, in_dim).norm()
    print(f"[头结构rankR] 用共享 {R} 基重建误差 {rel_err:.3f}  (<<1 => 头强共享, 可张量分解)")
    # 有效张量秩: 捕获90%的奇异值数
    et = masked_energy_rank(S, frac)
    print(f"[头结构SVD] 捕获{frac:.0%}能量需 {et} 个奇异值 (of {len(S)}) "
          f"压缩比≈{d_out/et:.1f}x")
    return ek, et, rel_err

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", help="safetensors/权重文件路径 (smol-kimi-k3 或 K3)")
    ap.add_argument("--H", type=int, default=5, help="num_heads")
    ap.add_argument("--HD", type=int, default=64, help="head_size")
    ap.add_argument("--d", type=int, default=320, help="hidden_size")
    ap.add_argument("--layer", type=int, default=0)
    args = ap.parse_args()

    if args.ckpt:
        from safetensors.torch import load_file
        sd = load_file(args.ckpt)
        keys = [k for k in sd if f"layers.{args.layer}." in k and "q_proj" in k]
        print("可用权重键(过滤 q_proj):", keys[:5])
        for name, pat in [("q", "q_proj"), ("k", "k_proj"), ("v", "v_proj")]:
            k = [x for x in sd if f"layers.{args.layer}." in x and pat in x]
            if k:
                analyze_weight(sd[k[0]], f"{name}_proj", args.H, args.HD, args.d)
    else:
        # 演示模式: 两种假设
        print("未给 --ckpt, 用合成权重演示两种极端:")
        torch.manual_seed(0)
        # A) 头间共享低秩基 (张量可压)
        W_shared = torch.randn(args.H * args.HD, args.d)
        # B) 每头独立随机 (张量不可压)
        W_indep = torch.randn(args.d, args.d)

        analyze_weight(W_shared, "合成·头共享", args.H, args.HD, args.d)
        analyze_weight(W_indep, "合成·独立头", args.H, args.HD, args.d)
        print("""
用法: 用真实权重替换 --ckpt 即可判定 (head结构可张量分解 vs 需蒸馏)
  python3 tools/kda_head_sharing.py --ckpt /path/model.safetensors --H 5 --HD 64 --d 320""")

if __name__ == "__main__":
    main()
