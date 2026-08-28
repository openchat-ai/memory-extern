#!/usr/bin/env python3
"""
distill_route_proxy.py — L3 「统计替身/路由代理」量化 (T11)

思路 (§6.7)：不完整算注意力 h_in, 改用小型可蒸馏替身来选专家。
L3 = 纯统计/层内偏好替身，只需历史路由轨迹 (layer, expert), 无需激活向量。

对每层用历史轨迹统计「专家被选中频率」→ 规则路由每层取 top16 →
与轨迹里真实被选中的专家比对命中率。
量化「统计替身」的天花板，作为 L1/L2 (需激活量) 的下限 baseline。

用法：
  python3 distill_route_proxy.py
"""
import struct
import os
from collections import Counter, defaultdict

L_MOE = 92
TOP_K = 16
TRACE = os.path.join(os.path.dirname(__file__), "..", "data", "expert_trace.bin")


def load_trace(path):
    d = open(path, "rb").read()
    recs = []
    for i in range(len(d) // 8):
        lay, exp = struct.unpack("<II", d[i * 8:i * 8 + 8])
        recs.append((lay, exp))
    return recs


def main():
    recs = load_trace(TRACE)
    # 按层统计被选中频率（真实轨迹 = 实际被 top16 选中的专家）
    per_layer_freq = defaultdict(Counter)
    per_layer_total = Counter()
    for (lay, exp) in recs:
        per_layer_freq[lay][exp] += 1
        per_layer_total[lay] += 1

    # 轨迹在每层的"真实唯一专家"（即真实 top16 的内容, 去重后）
    # 用于评估命中: 规则替身选的 top16 里, 多少落在该层真实出现过
    # 注: 轨迹是逐请求累计, 评估按"该层出现的全部唯一专家"作为真值池
    per_layer_unique = {lay: set(c.keys()) for lay, c in per_layer_freq.items()}

    # 轨迹结构: 每层是独立的一批记录(先采 layer1 多条, 再 layer2...),
    # 非 token→92层链条。因此逐层做"时序留一"评估:
    #   用该层前 k-1 条记录训练频率表 → 预测第 k 条的 top16, 看第 k 条真实专家是否命中
    # 这测的是「路由代理能否用历史预测下一次选中的专家」的泛化, 而非集合稳定性。
    per_layer = defaultdict(list)
    for (lay, exp) in recs:
        per_layer[lay].append(exp)

    total_pred = 0
    total_hit = 0
    for lay in range(1, L_MOE + 1):
        seq = per_layer[lay]
        if len(seq) < TOP_K + 1:
            continue
        freq = Counter()  # 滑动: 只用到上一条为止的历史
        # 先给前 TOP_K 条打底
        for e in seq[:TOP_K]:
            freq[e] += 1
        for i in range(TOP_K, len(seq)):
            target = seq[i]
            top16 = set(e for e, _ in freq.most_common(TOP_K))
            total_pred += 1
            if target in top16:
                total_hit += 1
            freq[seq[i]] += 1   # 学习当前这条
    hr_seq = total_hit / total_pred if total_pred else 0

    # 对照: 随机基线(pool 内乱猜)
    print(f"轨迹: {len(recs)} 条 (layer,expert), 每层独立批次")
    print(f"时序留一评估: 预测 {total_pred} 次 (每层逐条预测, 用此前历史)")
    print(f"[时序替身: 每层历史 top16]   命中率 = {hr_seq*100:.1f}%")
    print(f"[对照: 随机(match pool)]     ~{100*TOP_K/896:.1f}%")
    print(f"[参考: LRU 缓存 1GB]         ~35.4%")
    print(f"[参考: 预测线 ρ=0.279]       35.3%")

    # 干净分开: 集合稳定性 vs 时序预测
    stab = 0
    uniq_per_layer = {lay: set(v) for lay, v in per_layer.items()}
    print(f"\n集合稳定性: 每层唯一专家数")
    counts = sorted(((l, len(u)) for l, u in uniq_per_layer.items()), key=lambda x: -x[1])
    print(f"  平均每层唯一专家: {sum(c for _,c in counts)/len(counts):.1f} (共 {len(set(e for v in per_layer.values() for e in v))} 个全局专家)")


if __name__ == "__main__":
    main()
