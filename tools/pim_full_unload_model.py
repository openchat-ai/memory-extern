#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PIM 全 GEMV 卸载收益模型（2026-08-19 正式化）

对比两条路线在 Qwen3.6-35B-A3B-UD-Q3_K_S（实际 IQ 混合量化）上的 t/s 上限：
  A) CPU-only（现状）: 每 token 把 dense+专家权重从内存搬到 CPU 计算
  B) PIM 全 GEMV 卸载: dense+专家 GEMV 全部在内存侧算完, 只把结果向量传回 CPU

全部输入参数来自 GGUF offset 差实测（tools 目录 gguf_probe.py 在 WSL 的输出）
与真机时序（data/bscan/timing-mlock_*.log）。
"""

# ---- 输入参数（GGUF 实测）--------------------------------------------------
# 张量字节按 GGUF tensor offset 相邻差求得，合计 15.359GB = 文件大小，可靠
MODEL = {
    "name": "Qwen3.6-35B-A3B-UD-Q3_K_S.gguf",
    "file_bytes": 15.359e9,
    # 专家（IQ 混合，超低比特）
    "gate_exps_bytes": 4.110e9,   # IQ2_S, 40 层, 每层 256 专家 × (2048×512) 合并 gate+up
    "down_exps_bytes": 4.696e9,   # IQ1_M, 40 层, 每层 256 专家 × (512×2048)
    # dense（Q5_0 为主：SSM/attention/embedding/shared/router/norm）
    "dense_bytes":    6.553e9,
    "n_layers":       40,
    "n_experts":      256,        # 每层专家池
    "n_active":       8,          # 每层路由 top-k（Qwen3 默认 8）
    "hidden":         2048,
    "n_ff":           512,        # 专家中间维
    "dense_bpw":      5.5,        # Q5_0 = (32×5bit + 16bit scale)/32
}
# 真机实测（mlock 稳定态, data/bscan/timing-mlock_n100_*.log）
MEAS = {
    "cpu_only_tps": 4.25,         # 生成段 23.5s/100 token
    "cpu_only_bandwidth_gbs": 29, # = 每 token 读字节 × t/s（实测反推）
    "cpu_util_pct": 431,          # 8 线程只用了 ~4.3 核（内存等待特征）
}

# ---- 模型公式 --------------------------------------------------------------
def expert_gemv_macs(m):
    # 每层激活 n_active 个专家：gate_up(2048→512) + down(512→2048)
    per_exp = m["hidden"] * m["n_ff"] + m["n_ff"] * m["hidden"]
    return m["n_layers"] * m["n_active"] * per_exp

def dense_gemv_macs(m):
    # dense 权重元素数 = 字节 × 8 / bpw（Q5_0）
    return m["dense_bytes"] * 8.0 / m["dense_bpw"]

def per_token_comm_bytes(m):
    # PIM 内聚合后每层只传回 hidden 维 fp32 结果向量
    # dense 激活 + 专家加权输出（每层各 hidden×4B）+ 路由输出（n_experts×4B）
    per_layer = 2 * m["hidden"] * 4            # dense + 专家 输出
    router = m["n_experts"] * 4                # gate_inp 路由 logits
    return m["n_layers"] * per_layer + router

def cpu_nongemv_flops(m, seq):
    # CPU 侧非 GEMV：rmsnorm×2 + GLU 逐元素 + 残差 + softmax/逐元素
    # full-attention 10 层（每 4 层 1 个）：QK^T + softmax + AV，随 seq 增长
    per_layer_elewise = 2 * m["hidden"] + 2 * m["hidden"] + m["hidden"]
    elewise = m["n_layers"] * per_layer_elewise * 4          # ~4 FLOP/元素
    full_attn_layers = m["n_layers"] // 4                    # full_attention_interval=4
    attn = full_attn_layers * 2 * m["hidden"] * seq * seq * 2  # QK^T + AV，各 2 FLOP/MAC
    return elewise + attn

# ---- 输出 ------------------------------------------------------------------
def main():
    m = MODEL
    ex = expert_gemv_macs(m)
    ds = dense_gemv_macs(m)
    total_macs = ex + ds
    comm = per_token_comm_bytes(m)
    old_read = m["dense_bytes"] + m["n_layers"] * m["n_active"] * (
        m["gate_exps_bytes"] + m["down_exps_bytes"]) / (m["n_layers"] * m["n_experts"])

    print("=" * 72)
    print("PIM 全 GEMV 卸载收益模型  (数据源: GGUF offset 差实测 + mlock 真机时序)")
    print("=" * 72)
    print(f"模型: {m['name']}  {m['file_bytes']/1e9:.2f} GB")
    print(f"  dense {m['dense_bytes']/1e9:.3f} GB (Q5_0, {m['dense_bpw']}bpw)  "
          f"= {ds/1e9:.2f} G 元素/token 全量 GEMV")
    print(f"  专家  gate_up {m['gate_exps_bytes']/1e9:.3f} GB (IQ2_S) + "
          f"down {m['down_exps_bytes']/1e9:.3f} GB (IQ1_M), "
          f"{m['n_layers']} 层 × {m['n_experts']} 专家")
    print(f"  激活 {m['n_active']} 专家/层 → 专家 GEMV = {ex/1e9:.3f} G MACs/token")

    print("\n-- 每 token 数据移动 -------------------------------------------")
    print(f"  现状 CPU-only : 搬权重 {old_read/1e9:.3f} GB")
    print(f"  PIM 卸载后    : 传结果 {comm/1e3:.1f} KB  (缩小 {old_read/comm:,.0f} 倍)")
    print(f"  实测带宽      : {MEAS['cpu_only_bandwidth_gbs']} GB/s "
          f"(DDR4 双通道 3200 理论 51.2 的 {MEAS['cpu_only_bandwidth_gbs']/51.2*100:.0f}%)")
    print(f"  现状带宽墙    : {MEAS['cpu_only_bandwidth_gbs']*1e9/old_read:.2f} t/s "
          f"(实测 {MEAS['cpu_only_tps']} t/s 已贴墙 "
          f"{MEAS['cpu_only_tps']/(MEAS['cpu_only_bandwidth_gbs']*1e9/old_read)*100:.0f}%)")
    print(f"  CPU 利用率 {MEAS['cpu_util_pct']}% = 内存等待特征, 非算力不足")

    print("\n-- GEMV 计算量 ---------------------------------------------------")
    print(f"  dense GEMV : {ds/1e9:.2f} G MACs/token  ({ds/total_macs*100:.0f}%)")
    print(f"  专家 GEMV  : {ex/1e9:.3f} G MACs/token  ({ex/total_macs*100:.0f}%)")
    print(f"  合计       : {total_macs/1e9:.2f} G MACs/token")

    print("\n-- PIM 算力需求（新墙） -----------------------------------------")
    print(f"  {'目标 t/s':>10} {'需 PIM 算力 (TFLOP/s)':>22}  备注")
    for t in (20, 40, 100, 250, 500):
        flops = total_macs * 2 * t / 1e12
        note = ""
        if t == 40:
            note = "≈ sim_cim 判决的 50 tok/s 同量级"
        elif t == 250:
            note = "≈ 每 token 7.5ms GEMV"
        print(f"  {t:>10} {flops:>22.2f}  {note}")

    print("\n-- CPU 侧剩余（非 GEMV）------------------------------------------")
    cpu_flops = 8 * 3.0e9 * 16  # 8 核 × 3.0GHz × AVX2 FMA 16 FLOP
    print(f"  CPU 峰值 ≈ {cpu_flops/1e12:.2f} TFLOP/s (8 核 AVX2)")
    for seq in (128, 1024, 4096):
        ele = m["n_layers"] * (2 * m["hidden"] + 2 * m["hidden"] + m["hidden"]) * 4
        f = cpu_nongemv_flops(m, seq)
        dom = "attention 主导" if (f - ele) > ele else "逐元素主导"
        print(f"  seq={seq:>5}: 非 GEMV {f/1e6:.0f} M FLOP/token → {f/cpu_flops*1e3:.1f} ms  ({dom})")
    print("  注: seq≥1024 时 full-attention(10 层) 成新墙; QK^T/AV 也是 GEMV, 可继续下沉")
    print("       CPU 只留 softmax/逐元素/路由/采样")

    print("\n-- 结论 -----------------------------------------------------------")
    print("  1. 卸载全部 GEMV 后, 数据移动从 %.2f GB 降到 %.0f KB/token (×%.0f)"
          % (old_read/1e9, comm/1e3, old_read/comm))
    print("  2. 通信墙消失; 新墙 = PIM 算力 (%.2f G MACs/token; 40 t/s 需 ~0.8 TFLOP/s)"
          % (total_macs/1e9,))
    print("  3. CPU 只留非 GEMV: 短序列微秒级; 长序列(seq>=1024) attention 成墙, 需下沉 QK^T/AV")
    print("  4. 相对现状 4.25 t/s, PIM 全卸载上限 = 40-100+ t/s (视 crossbar 算力)")
    print("  5. 旧判定 '本机瓶颈在算力而非带宽' 作废: 实测 4.25 已贴带宽墙 "
          "(29GB/s, 见 notes 修正标注)")

if __name__ == "__main__":
    main()
