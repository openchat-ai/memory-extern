#!/usr/bin/env python3
"""
头共享度曲线诊断(torch, 真实权重)—— 补 kda_tensor_decompose 的 head_err_R4 单点缺陷。
区分两种截然不同的"失败":
  A) 重构误差随 rank 增大而#SMOOTH下降 -> 只是 rank 不够, 头间有共享, 有救(§14公共基)
  B) 重构误差随 rank 增大也掉不下来 -> 头间真无共享(Per-Head Muon独立性), 满秩墙, 死(§12)

不是测"整体矩阵低秩度"(那会误导), 而是直接测「跨头是否共享同一低秩列空间」:
  把 H 个头的输出严格看作 H 个 [HD, di] 子块, 算"所有头合并起来能否被 k 个
  共享基承载"的相对误差, 扫 k=4/16/64/128/256/全。
  + 附: 各头列空间两两夹角(PCA overlap) → 直接看头间是否独立。

用法:
  python3 tools/kda_head_sharing_curve.py --ckpt model.safetensors \
      --key layers.0.q_proj.weight --H 96 --HD 128
  (smol:          --key ... --H 5 --HD 64)
"""
import argparse, math

def run(ckpt, key, H, HD):
    import torch
    from safetensors.torch import load_file
    sd = load_file(ckpt)
    if key not in sd:
        cands = [k for k in sd if "q_proj" in k]
        print(f"key '{key}' 不存在. 候选(q_proj):")
        for c in cands[:20]: print("  ", c)
        return
    W = sd[key].float()
    do, di = W.shape
    if do != H * HD:
        print(f"警告: shape {do}x{di} != H*HD={H}*{HD}={H*HD}")
    Wr = W.view(H, HD, di)  # [H, HD, di]
    print(f"检查 {key}  [{do}x{di}] 重排 [H={H}, HD={HD}, di={di}]")

    # 合并所有头 -> 跨头共享度: 用 SVD 找"全局公共基"承载所有头的能力
    M = Wr.reshape(H * HD, di)  # [H*HD, di]
    s = torch.linalg.svdvals(M)
    total_e = (s * s).sum()

    print(f"\n[跨头共享度] 用 k 个全局公共基承载所有头, 捕获能量/相对误差:")
    # 捕获能量 = 前k个奇异值平方 / 总能量; 相对误差 = sqrt(1 - 捕获比)
    for k in [4, 16, 64, 128, 256, 512, min(1024, di)]:
        if k > len(s): break
        cap = (s[:k] * s[:k]).sum() / total_e
        rel = math.sqrt(max(0.0, 1 - cap))
        mark = "<=够" if rel < 0.1 else ("~中" if rel < 0.3 else "=>不足")
        print(f"   k={k:>5}: 捕获能量{cap:.1%}  相对重构误差{rel:.3f}  {mark}")
    print(f"   奇异值谱(前12): " + " ".join(f"{x:.2f}" for x in s[:12].tolist()))
    print(f"   σ1/σ_min={s[0]/ (s[-1]+1e-9):.1f}   (接近1=>满秩均匀分布)")

    # 头间两两独立性: 各头列空间的公共维度占比(简化: 全头合并空间的维数 vs 单头)
    print(f"\n[头间独立性] 单头[HD={HD}x{di}]的有效秩 vs 全头合并有效秩(得全能量需k):")
    # 每头独立 SVD 90%能量秩
    r_heads = []
    for h in range(min(H, 8)):
        sh = torch.linalg.svdvals(Wr[h])
        s2 = sh * sh; tot = s2.sum(); acc = 0.0
        for i in range(len(sh)):
            acc += s2[i]
            if acc / tot >= 0.9: r_heads.append(i + 1); break
    if r_heads: print(f"   各头rank90(前{len(r_heads)}头): {r_heads} (均值{sum(r_heads)/len(r_heads):.0f})")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--key", required=True, help="如 layers.0.attn.q_proj.weight")
    ap.add_argument("--H", type=int, default=96)
    ap.add_argument("--HD", type=int, default=128)
    o = ap.parse_args()
    run(o.ckpt, o.key, o.H, o.HD)

if __name__ == "__main__":
    main()
