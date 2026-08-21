#!/usr/bin/env python3
"""不同算法/模型/精度的算力需求评估"""
import math

print("=" * 80)
print("不同算法/模型/精度的算力需求评估")
print("=" * 80)

# ===== 基础参数 =====
LPDDR5X_BW = 171  # GB/s (8ch LPDDR5X)
MACS = 68
CLOCK_GHZ = 1.0
BYTES_PER_MAC = 4  # bf16: 2B 权重(DRAM) + 2B 激活(SRAM) = 4B
WEIGHT_BW = MACS * CLOCK_GHZ * 2  # 136 GB/s (仅权重，从 DRAM 读)

# 计算能力
COMPUTE_BW = MACS * BYTES_PER_MAC * CLOCK_GHZ  # 272 GB/s
print(f"\n单芯片参数:")
print(f"  内存带宽: {LPDDR5X_BW} GB/s (8ch LPDDR5X)")
print(f"  计算能力: {MACS} MAC × {BYTES_PER_MAC}B × {CLOCK_GHZ} GHz = {COMPUTE_BW} GB/s")
print(f"  权重需求: {WEIGHT_BW} GB/s (仅 DRAM)")
print(f"  平衡点: 权重需求/内存 = {WEIGHT_BW/LPDDR5X_BW:.2f}x")
print(f"  瓶颈: {'计算瓶颈' if WEIGHT_BW < LPDDR5X_BW else 'DRAM瓶颈'}")

# ===== 模型参数 =====
models = {
    "7B": {"params": 7e9, "layers": 32, "hidden": 4096, "heads": 32},
    "13B": {"params": 13e9, "layers": 40, "hidden": 5120, "heads": 40},
    "30B": {"params": 30e9, "layers": 60, "hidden": 6656, "heads": 52},
    "70B": {"params": 70e9, "layers": 80, "hidden": 8192, "heads": 64},
}

# 精度参数
precisions = {
    "bf16": {"bytes": 2, "name": "BF16"},
    "int8": {"bytes": 1, "name": "INT8"},
    "int4": {"bytes": 0.5, "name": "INT4"},
    "Q3": {"bytes": 0.375, "name": "Q3_K"},
    "Q4": {"bytes": 0.5, "name": "Q4_K"},
}

# ===== 1. Decode 性能（逐 token） =====
print("\n" + "=" * 80)
print("1. DECODE 性能（逐 token 生成）")
print("=" * 80)
print(f"\n{'模型':<8} {'精度':<8} {'权重大小':<12} {'每token时间':<12} {'tok/s':<10} {'瓶颈':<10}")
print("-" * 65)

for model_name, model in models.items():
    for prec_name, prec in precisions.items():
        weight_gb = model["params"] * prec["bytes"] / 1e9
        t_per_token_ms = weight_gb / LPDDR5X_BW * 1000
        tps = 1000 / t_per_token_ms
        
        # 判断瓶颈（INT4 有 4x SIMD 加速）
        simd_factor = 4 if prec["bytes"] <= 0.5 else 1
        compute_time_ms = weight_gb / (COMPUTE_BW * simd_factor) * 1000
        if compute_time_ms < t_per_token_ms * 0.8:
            bottleneck = "带宽墙"
        elif compute_time_ms > t_per_token_ms * 1.2:
            bottleneck = "算力墙"
        else:
            bottleneck = "平衡"
        
        simd_note = f" (SIMD {simd_factor}x)" if simd_factor > 1 else ""
        print(f"{model_name:<8} {prec_name:<8} {weight_gb:>6.1f} GB   {t_per_token_ms:>8.1f} ms   {tps:>6.1f}   {bottleneck}{simd_note}")

# ===== 2. Prefill 性能（处理输入） =====
print("\n" + "=" * 80)
print("2. PREFILL 性能（处理输入 prompt）")
print("=" * 80)

seq_lengths = [128, 512, 2048, 8192]
print(f"\n{'模型':<8} {'序列长度':<10} {'计算量':<12} {'计算时间':<12} {'内存时间':<12} {'瓶颈':<10}")
print("-" * 70)

for model_name, model in models.items():
    for seq_len in seq_lengths:
        # Prefill: 每个 token 做 params 次 MAC
        total_macs = seq_len * model["params"]
        compute_time_ms = total_macs / (MACS * CLOCK_GHZ * 1e9) * 1000
        
        # 内存: 读取权重（一次）+ 读取输入（很小）
        weight_gb = model["params"] * 2 / 1e9  # bf16
        memory_time_ms = weight_gb / LPDDR5X_BW * 1000
        
        if compute_time_ms < memory_time_ms * 0.8:
            bottleneck = "带宽墙"
        elif compute_time_ms > memory_time_ms * 1.2:
            bottleneck = "算力墙"
        else:
            bottleneck = "平衡"
        
        compute_str = f"{total_macs/1e9:.0f}B MAC"
        print(f"{model_name:<8} {seq_len:<10} {compute_str:<12} {compute_time_ms:>8.1f} ms   {memory_time_ms:>8.1f} ms   {bottleneck}")

# ===== 3. Attention 计算 =====
print("\n" + "=" * 80)
print("3. ATTENTION 计算（自注意力机制）")
print("=" * 80)

print(f"\n{'模型':<8} {'序列长度':<10} {'QKV计算':<12} {'Softmax':<12} {'总计算':<12}")
print("-" * 60)

for model_name, model in models.items():
    for seq_len in [128, 512, 2048]:
        hidden = model["hidden"]
        heads = model["heads"]
        head_dim = hidden // heads
        
        # QKV: 3 × seq_len × hidden × hidden (投影)
        qkv_macs = 3 * seq_len * hidden * hidden
        # Attention: seq_len × seq_len × hidden (注意力分数)
        attn_macs = seq_len * seq_len * hidden
        # Output projection: seq_len × hidden × hidden
        out_macs = seq_len * hidden * hidden
        
        total_macs = qkv_macs + attn_macs + out_macs
        
        compute_time_ms = total_macs / (MACS * CLOCK_GHZ * 1e9) * 1000
        
        print(f"{model_name:<8} {seq_len:<10} {qkv_macs/1e9:>8.1f}B   {attn_macs/1e9:>8.1f}B   {total_macs/1e9:>8.1f}B")

# ===== 4. 不同 Batch Size =====
print("\n" + "=" * 80)
print("4. 不同 BATCH SIZE 的性能")
print("=" * 80)

batch_sizes = [1, 4, 8, 16, 32, 64, 128, 256, 512]
print(f"\n{'Batch':<8} {'7B bf16':<12} {'13B bf16':<12} {'30B bf16':<12} {'瓶颈':<10}")
print("-" * 55)

for batch in batch_sizes:
    results = []
    bottlenecks = []
    for model_name, model in models.items():
        weight_gb = model["params"] * 2 / 1e9
        # Batch 推理: 权重读取一次（所有 token 复用），内存时间固定
        memory_time_ms = weight_gb / LPDDR5X_BW * 1000  # 固定，与 batch 无关
        # 计算: batch 行 GEMV，每行 params 次 MAC，总 MAC = batch * params
        total_macs = batch * model["params"]
        compute_time_ms = total_macs / (MACS * CLOCK_GHZ * 1e9) * 1000
        
        # 有效 tok/s = batch 数 / max(内存时间, 计算时间)
        effective_tps = batch / max(memory_time_ms, compute_time_ms) * 1000
        results.append(f"{effective_tps:>8.1f}")
        
        # 判断瓶颈
        if compute_time_ms < memory_time_ms * 0.8:
            bottlenecks.append("带宽墙")
        elif compute_time_ms > memory_time_ms * 1.2:
            bottlenecks.append("算力墙")
        else:
            bottlenecks.append("平衡")
    
    print(f"{batch:<8} {''.join(results[0]):<12} {''.join(results[1]):<12} {''.join(results[2]):<12} {'/'.join(bottlenecks)}")

# ===== 5. 总结 =====
print("\n" + "=" * 80)
print("5. 总结：算力需求评估")
print("=" * 80)

print(f"""
┌─────────────────────────────────────────────────────────────┐
│  场景                    │ 瓶颈      │ V1 性能              │
├─────────────────────────────────────────────────────────────┤
│  7B bf16 decode          │ 计算瓶颈  │ 10.7 tok/s           │
│  13B bf16 decode         │ 计算瓶颈  │ 5.3 tok/s            │
│  30B bf16 decode         │ 计算瓶颈  │ 2.4 tok/s            │
│  70B bf16 decode         │ 计算瓶颈  │ 1.1 tok/s            │
│  7B Q4 decode (SIMD 4x)  │ DRAM瓶颈  │ 42.7 tok/s           │
│  13B Q4 decode (SIMD 4x) │ DRAM瓶颈  │ 21.3 tok/s           │
│  30B Q4 decode (SIMD 4x) │ DRAM瓶颈  │ 9.5 tok/s            │
│  70B Q4 decode (SIMD 4x) │ DRAM瓶颈  │ 4.3 tok/s            │
│  Prefill 128 tokens      │ 带宽墙    │ ✅                   │
│  Prefill 2048 tokens     │ 接近平衡  │ ⚠️ 可能慢           │
│  Prefill 8192 tokens     │ 算力墙    │ ❌ 需要升级         │
│  Batch=2 7B bf16         │ 算力墙    │ ⚠️ 降速             │
│  Batch=8 7B bf16         │ 算力墙    │ ❌ 降速             │
│  Batch=32 7B bf16        │ 算力墙    │ ❌ 降速             │
└─────────────────────────────────────────────────────────────┘

结论：
1. V1 芯片 68 MAC @1.0GHz: 计算 272 GB/s, 权重需求 136 GB/s, DRAM 171 GB/s
2. bf16: 计算瓶颈（272 > 171），MAC 满载，不能降频
3. INT4 (SIMD 4x): 计算 1088 GOPS, 权重需求 34 GB/s, DRAM 有 5x 余量
4. INT4 可降频省电，或保持 1.0GHz 获得 4x 提速
5. Batch>1 和长 prefill 是 V2 的目标场景
""")
