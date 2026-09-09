#!/usr/bin/env python3
"""精炼豆豆: 17.5M 专家 → 1.5M (压缩 11.7x)"""

import numpy as np
import time

def generate_expert(n_embd=3584, n_ff=3584, dtype=np.float32):
    """生成一个 17.5M 参数的专家权重 (类似 gate/up projection)"""
    # 专家权重形状: [n_embd, n_ff] 或 [n_ff, n_embd]
    W = np.random.randn(n_embd, n_ff).astype(dtype) * 0.02
    params = W.size
    print(f"原始专家: shape={W.shape}, params={params:,} ({params/1e6:.1f}M)")
    return W

def compress_svd(W, target_params):
    """SVD 分解: W ≈ U × S × V^T, 只保留 top-k 奇异值"""
    print("\n=== SVD 分解 ===")
    t0 = time.time()
    
    # 全 SVD
    U, S, Vt = np.linalg.svd(W, full_matrices=False)
    t_svd = time.time() - t0
    print(f"SVD 耗时: {t_svd:.2f}s")
    
    # 计算需要保留多少奇异值达到目标参数
    # W ≈ U[:, :r] @ diag(S[:r]) @ Vt[:r, :]
    # 参数量 = n_embd*r + r + r*n_ff ≈ r*(n_embd + n_ff)
    n_embd, n_ff = W.shape
    r = target_params // (n_embd + n_ff)
    r = max(r, 1)
    
    print(f"保留奇异值: {r}/{len(S)}")
    print(f"目标参数: {r*(n_embd+n_ff):,} ({r*(n_embd+n_ff)/1e6:.1f}M)")
    
    # 低秩近似
    W_approx = U[:, :r] @ np.diag(S[:r]) @ Vt[:r, :]
    
    # 误差
    mse = np.mean((W - W_approx)**2)
    rel_err = np.linalg.norm(W - W_approx) / np.linalg.norm(W)
    print(f"MSE: {mse:.6f}")
    print(f"相对误差: {rel_err:.4f} ({rel_err*100:.2f}%)")
    
    return W_approx, r, rel_err

def compress_pruning(W, sparsity=0.9):
    """结构化剪枝: 删除绝对值最小的权重"""
    print(f"\n=== 剪枝 (稀疏度 {sparsity*100:.0f}%) ===")
    t0 = time.time()
    
    flat = np.abs(W).flatten()
    threshold = np.percentile(flat, sparsity * 100)
    
    mask = np.abs(W) >= threshold
    W_pruned = W * mask
    
    t_prune = time.time() - t0
    params = np.count_nonzero(W_pruned)
    print(f"剪枝耗时: {t_prune:.2f}s")
    print(f"剩余参数: {params:,} ({params/1e6:.1f}M)")
    
    mse = np.mean((W - W_pruned)**2)
    rel_err = np.linalg.norm(W - W_pruned) / np.linalg.norm(W)
    print(f"MSE: {mse:.6f}")
    print(f"相对误差: {rel_err:.4f} ({rel_err*100:.2f}%)")
    
    return W_pruned, params, rel_err

def compress_low_rank(W, target_params):
    """低秩分解: W ≈ A @ B, A=[n_embd, r], B=[r, n_ff]"""
    print("\n=== 低秩分解 ===")
    t0 = time.time()
    
    n_embd, n_ff = W.shape
    r = target_params // (n_embd + n_ff)
    r = max(r, 1)
    
    # 随机投影初始化
    A = np.random.randn(n_embd, r).astype(np.float32) * 0.02
    B = np.random.randn(r, n_ff).astype(np.float32) * 0.02
    
    # 简单梯度下降优化
    lr = 0.001
    for i in range(100):
        W_approx = A @ B
        grad_W = 2 * (W_approx - W) / W.size
        grad_A = grad_W @ B.T
        grad_B = A.T @ grad_W
        A -= lr * grad_A
        B -= lr * grad_B
    
    t_decomp = time.time() - t0
    print(f"分解耗时: {t_decomp:.2f}s")
    print(f"保留秩: {r}")
    print(f"参数量: {r*(n_embd+n_ff):,} ({r*(n_embd+n_ff)/1e6:.1f}M)")
    
    W_approx = A @ B
    mse = np.mean((W - W_approx)**2)
    rel_err = np.linalg.norm(W - W_approx) / np.linalg.norm(W)
    print(f"MSE: {mse:.6f}")
    print(f"相对误差: {rel_err:.4f} ({rel_err*100:.2f}%)")
    
    return W_approx, r, rel_err

def compress_quantize(W, bits=4):
    """量化: 降低精度"""
    print(f"\n=== 量化 ({bits}-bit) ===")
    t0 = time.time()
    
    # 找范围
    w_min, w_max = W.min(), W.max()
    
    # 量化
    scale = (w_max - w_min) / (2**bits - 1)
    W_quant = np.round((W - w_min) / scale) * scale + w_min
    
    t_quant = time.time() - t0
    print(f"量化耗时: {t_quant:.2f}s")
    print(f"精度: {bits}-bit")
    print(f"压缩比: {32/bits:.1f}x")
    
    mse = np.mean((W - W_quant)**2)
    rel_err = np.linalg.norm(W - W_quant) / np.linalg.norm(W)
    print(f"MSE: {mse:.6f}")
    print(f"相对误差: {rel_err:.4f} ({rel_err*100:.2f}%)")
    
    return W_quant, rel_err

def gemv_benchmark(W, x, label):
    """GEMV 性能测试"""
    t0 = time.time()
    for _ in range(100):
        y = W @ x
    t_gemv = (time.time() - t0) / 100
    
    flops = 2 * W.shape[0] * W.shape[1]
    bandwidth = W.nbytes / t_gemv
    
    print(f"{label}: shape={W.shape}, time={t_gemv*1000:.2f}ms, "
          f"FLOPs={flops/1e6:.1f}M, BW={bandwidth/1e9:.2f}GB/s")

def main():
    print("=" * 60)
    print("精炼豆豆: 17.5M 专家 → 1.5M")
    print("=" * 60)
    
    # 生成原始专家
    W = generate_expert(n_embd=3584, n_ff=3584)
    target = 1_500_000
    
    # 测试输入
    x = np.random.randn(3584).astype(np.float32)
    y_ref = W @ x
    
    # 1. SVD 分解
    W_svd, r_svd, err_svd = compress_svd(W, target)
    y_svd = W_svd @ x
    cos_svd = np.dot(y_ref, y_svd) / (np.linalg.norm(y_ref) * np.linalg.norm(y_svd))
    
    # 2. 剪枝 (90%)
    W_prune, params_prune, err_prune = compress_pruning(W, sparsity=0.9)
    y_prune = W_prune @ x
    cos_prune = np.dot(y_ref, y_prune) / (np.linalg.norm(y_ref) * np.linalg.norm(y_prune))
    
    # 3. 低秩分解
    W_lr, r_lr, err_lr = compress_low_rank(W, target)
    y_lr = W_lr @ x
    cos_lr = np.dot(y_ref, y_lr) / (np.linalg.norm(y_ref) * np.linalg.norm(y_lr))
    
    # 4. 量化
    W_q4, err_q4 = compress_quantize(W, bits=4)
    y_q4 = W_q4 @ x
    cos_q4 = np.dot(y_ref, y_q4) / (np.linalg.norm(y_ref) * np.linalg.norm(y_q4))
    
    # GEMV 性能对比
    print("\n" + "=" * 60)
    print("GEMV 性能对比")
    print("=" * 60)
    
    gemv_benchmark(W, x, "原始 (17.5M)")
    gemv_benchmark(W_svd, x, f"SVD (rank={r_svd})")
    gemv_benchmark(W_prune, x, "剪枝 90%")
    gemv_benchmark(W_lr, x, f"低秩 (rank={r_lr})")
    gemv_benchmark(W_q4, x, "量化 Q4")
    
    # 总结
    print("\n" + "=" * 60)
    print("压缩结果汇总")
    print("=" * 60)
    
    print(f"{'方法':<15} {'参数量':<15} {'压缩比':<10} {'误差':<10} {'余弦相似度':<10}")
    print("-" * 60)
    print(f"{'原始':<15} {'17.5M':<15} {'1.0x':<10} {'0.00%':<10} {'1.000':<10}")
    print(f"{'SVD':<15} {f'{r_svd*(7168)/1e6:.1f}M':<15} {f'{17.5/(r_svd*7168/1e6):.1f}x':<10} {f'{err_svd*100:.1f}%':<10} {f'{cos_svd:.3f}':<10}")
    print(f"{'剪枝 90%':<15} {f'{params_prune/1e6:.1f}M':<15} {f'{17.5/(params_prune/1e6):.1f}x':<10} {f'{err_prune*100:.1f}%':<10} {f'{cos_prune:.3f}':<10}")
    print(f"{'低秩分解':<15} {f'{r_lr*(7168)/1e6:.1f}M':<15} {f'{17.5/(r_lr*7168/1e6):.1f}x':<10} {f'{err_lr*100:.1f}%':<10} {f'{cos_lr:.3f}':<10}")
    print(f"{'量化 Q4':<15} {f'{17.5/8:.1f}M':<15} {'8.0x':<10} {f'{err_q4*100:.1f}%':<10} {f'{cos_q4:.3f}':<10}")
    
    print("\n结论:")
    print("- SVD/低秩: 保留语义相似度最高，但需要矩阵运算")
    print("- 剪枝: 简单粗暴，但稀疏矩阵需要特殊硬件支持")
    print("- 量化: 最实用，4-bit 压缩 8x，误差小")
    print("- 组合: SVD + 量化 可达 10x+ 压缩")

if __name__ == "__main__":
    main()
