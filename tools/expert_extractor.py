#!/usr/bin/env python3
"""
expert_extractor.py — 「先路由后搬运」收益实测（T8）

背景（见 notes/kda-mla-decompose.md §6）：
  K3 是 Stable LatentMoE（sglang/kimi_linear.py 源码实锤）：
    router_logits = gate.weight ⊗ h_in        # gate.weight 7168×896，可常驻
    top16 = argmax(router_logits + correction_bias)
  → router 权重极小可常驻；注意力算完后瞬间拿到 h_in → 算出 top16 →
    只精准搬运/读取那 16 个专家本体，省掉 880/896 的专家读取。

本工具用真实路由轨迹（data/expert_trace.bin，100K 条 (layer, expert) 对）
量化「先路由后搬运」相对「整层读」的搬运量省幅。

真实参数（k3-verdict.md 逐字节实测）：
  L_moe      = 92
  E          = 896
  top_k      = 16
  expert_GB  = 17.55 MB = 17.55/1024 GB  每个专家本体（w1+w2+w3 packed+scale）

三种读取模式的每-token 搬运量对比：
  A) 整层读   : Σ_层 E×expert_GB        —— 读全部 896，实际没人这么做，但揭示浪费
  B) 先路由   : Σ_层 top_k×expert_GB    —— 理想下界（每层只读命中 16 个）
  C) 缓存加速 : 在 B 基础上叠加 LRU 缓存（真实 trace 实测命中率）

用法：
  python3 expert_extractor.py                 # 全量真实 trace
  python3 expert_extractor.py --cache-gb 1    # 带 1GB LRU 缓存
"""

import argparse
import struct
import os
from collections import OrderedDict

# ── K3 真实参数（k3-verdict.md 实测）────────────────────────
L_MOE     = 92
N_EXPERTS = 896
TOP_K     = 16
EXPERT_GB = 17.55 / 1024            # 每专家本体 17.55MB → GB

TRACE = os.path.join(os.path.dirname(__file__), "..", "data", "expert_trace.bin")


class LRUCache:
    """对象粒度 = 一个 (layer, expert) 切片（缓存最小单元 = 单专家本体）"""
    def __init__(self, cap_objects):
        self.cap = cap_objects
        self.od = OrderedDict()

    def access(self, key):
        if key in self.od:
            self.od.move_to_end(key)
            return True
        if len(self.od) >= self.cap:
            self.od.popitem(last=False)
        self.od[key] = 1
        return False


def load_trace(path):
    """读取真实 (layer, expert) 轨迹"""
    d = open(path, "rb").read()
    n = len(d) // 8
    recs = []
    for i in range(n):
        lay, exp = struct.unpack("<II", d[i * 8:i * 8 + 8])
        recs.append((lay, exp))
    return recs


def read_all_mode(tokens):
    """模式 A：每 token 整层读（读全部 896 专家 / 层）"""
    per_token = L_MOE * N_EXPERTS * EXPERT_GB
    return {"per_token": per_token,
            "total": per_token * tokens,
            "desc": f"整层读（每 token 读 {L_MOE}层×{N_EXPERTS}专家 全量）"}


def route_first_mode(tokens):
    """模式 B：先路由后搬运（每层只读命中 top16）——理想下界"""
    per_token = L_MOE * TOP_K * EXPERT_GB
    return {"per_token": per_token,
            "total": per_token * tokens,
            "desc": f"先路由后搬运（每 token 读 {L_MOE}层×{TOP_K} 命中专家）"}


def cache_mode(recs, cache_gb):
    """模式 C：先路由后搬运 + LRU 缓存（真实 trace 测命中）"""
    cap_objects = int(cache_gb / EXPERT_GB)          # GB → 可容纳专家数
    cache = LRUCache(cap_objects)
    unique_seen = {}
    token_gb = {}
    token_id = 0
    cur_token = []
    total_gb = 0.0
    # 按 token 分组（trace 是连续的 → 顺序切分，每 92 层为 token）
    # 但真实 trace 可能不带 token 边界；这里按记录切分累计每 token 流量
    hits = 0
    for (lay, exp) in recs:
        key = (lay, exp)
        if cache.access(key):
            hits += 1
        else:
            total_gb += EXPERT_GB                      # 未命中才搬运
    hit_rate = hits / len(recs)
    per_token = total_gb  # trace 总量对应累积（除以 token 数由外层给）
    return {"hits": hits, "hit_rate": hit_rate,
            "total": total_gb, "per_token": total_gb,
            "desc": f"先路由后搬运 + {cache_gb}GB LRU 缓存"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", default=TRACE)
    ap.add_argument("--cache-gb", type=float, default=None,
                    help="启用带缓存的模式 C，并指定缓存容量(GB)")
    args = ap.parse_args()

    recs = load_trace(args.trace)
    n_rec = len(recs)
    print(f"真实轨迹: {n_rec} 条 (layer,expert) 对")
    print(f"K3 参数:   {L_MOE} MoE 层 × {N_EXPERTS} 专家，top-{TOP_K}，"
          f"单专家 {EXPERT_GB*1024:.2f} MB")

    # ── 核心度量：每个 token 每层，专家本体的搬运量 ──
    # 模式 A：整层读 = 每层读全部 896
    a_layer = N_EXPERTS * EXPERT_GB                      # GB / (token·层)
    # 模式 B：先路由后搬运 = 每层只读命中的 16 个
    b_layer = TOP_K * EXPERT_GB                          # GB / (token·层)

    a_tok = L_MOE * a_layer                              # GB / token
    b_tok = L_MOE * b_layer                              # GB / token

    print("\n[每 token 流量 —— 专家本体部分]")
    print(f"[A] 整层读        : {a_tok:9.2f} GB/token  ({a_layer*1024:.1f} MB/层)")
    print(f"[B] 先路由后搬运  : {b_tok:9.2f} GB/token  ({b_layer*1024:.1f} MB/层)")
    save = (1 - b_tok / a_tok) * 100
    print(f"    省幅 = {save:.1f}%  (只搬命中 {TOP_K}/{N_EXPERTS}，比值 "
          f"{TOP_K}/{N_EXPERTS} = {TOP_K/N_EXPERTS*100:.3f}%)")

    # ── 模式 C：真实 trace 命中率 + 缓存 ──
    print(f"\n[真实 trace: {n_rec} 条]")
    # 去重层·专家数（触及池子）
    uniq = set(recs)
    print(f"  唯一 (layer,expert): {len(uniq)}  (触及池子 {len(uniq)/(L_MOE*N_EXPERTS)*100:.1f}%)")
    # 每 token 实际唯一专家（平均触及）
    # 按 layer 分组看每层实际用到的不同专家
    per_layer_uniq = {}
    for (lay, _) in recs:
        per_layer_uniq[lay] = per_layer_uniq.get(lay, 0) + 0
    # 真正有意义：trace 只是命中样本，B 模式的"读 top16"是路由决定的，不是 trace 决定
    # 这里只展示：如果命中缓存，能省多少

    if args.cache_gb is not None:
        cap = int(args.cache_gb / EXPERT_GB)
        cache = LRUCache(cap)
        hits = 0
        for key in recs:
            hits += 1 if cache.access(key) else 0
        hit_rate = hits / n_rec
        # 未命中才搬运专家本体
        eff_layer = b_layer * (1 - hit_rate)             # 每层每 token
        eff_tok = L_MOE * eff_layer
        print(f"  [{args.cache_gb}GB LRU] 命中率 = {hit_rate*100:.1f}%")
        print(f"  实际搬运(先路由+缓存) = {eff_tok:9.2f} GB/token")
        print(f"  相对整层读 A 省幅 = {(1 - eff_tok/a_tok)*100:.1f}%")

    print("\n结论:")
    print(f"  • 「先路由后搬运」把专家读取压到命中 {TOP_K}/{N_EXPERTS}")
    print(f"    = {b_tok/a_tok*100:.2f}%，省 {save:.1f}%")
    print(f"  • 若再叠加缓存（命中 {args.cache_gb or 0}GB），未命中才搬，进一步压降")
    print(f"  • 注意：down_proj/up_proj 为全体专家共享稠密墙（trunk 36GB 已计入，不在此省幅内）")


if __name__ == "__main__":
    main()
