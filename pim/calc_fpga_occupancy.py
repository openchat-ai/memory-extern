#!/usr/bin/env python3
"""calc_fpga_occupancy.py — Tang Mega 138K Pro 资源占用与吞吐上限计算器

用途：把散落在 independent-stack.md 里的 LUT/DSP 占用、lane 上限、
      带宽实顶全部参数化，可改参复算，替代手算表格。

口径来源：
  - 官方规格：Sipeed wiki mega-138k-pro.html（2025-01-24 v0.3）
  - 总线位宽：LiteX sipeed_tang_mega_138k_pro.py（DQ=32, DQS×4 对）
  - 组件成本：rtl/12_fpga_proto/rtl/simd_mac_array.v 注释（每完整 lane ~90 LUT）
  - lane 划分：independent-stack.md §3.5 / §3.6（乘核 ~4-12 LUT，含累加器 ~90）
  - K3 流量：k3-verdict 实测（专家 mxfp4 落盘 25.83GB/token；trunk fp16 保精度）

2026-08-29 修正（owner 拍板 3 条）：
  ① 链路瓶颈 = min(主机NAND, PCIe 上游, DDR3)，不是只算 DDR3。
  ② 精度分裂：专家走 mxfp4 查表 SIMD；trunk 保留 fp16 → 走 bf16 通道，
      SIMD 查表对 fp16 失灵（bf16 乘累加是实数积，不是 256 组合查表）。
  ③ SIMD 只省乘法不省加法：完整 lane 口径（含累加器/归约树）才是真实占用；
      纯乘核 12 LUT/lane 是乐观下限。
  ④ trunk fp16 → 每 token 读 108.8GB（非量化 36GB），流量账重算。

校验提示：文档内存在两套 lane 成本口径（~12 纯查表 vs ~90 完整通道），
本脚本两者都算，并输出与文档百分比的残差，供校准。
"""
import sys

# ═══════════════════════ 1. 官方基线（Sipeed wiki / LiteX 实证）═══════════════
FPGA = {
    "name":   "Tang Mega 138K Pro (GW5AST-LV138FPG676A)",
    "lut":    138_240,            # LUT4，官方
    "dsp":    298,                # 18×18 乘法器，官方（笔记旧值 192 已废）
    "bsram_kbit": 6_120,          # 块 SRAM 总量 Kbit
    "bsram_blocks": 340,          # 块数
    "dram_mts": 1_333,            # DDR3 MT/s per pin
    "dram_bus_bits": 32,          # LiteX 实证 DQ=32
    "pcie_gen": 3,
    "pcie_lanes_max": 8,
    # PCIe 链路上游（板上走 x4）
    "pcie_lanes_used": 4,         # 板上实际走 x4（wiki Board Features）
}

# ═══════════════════════ 2. 组件成本模型（可调参数）═══════════════════════════
COMPONENT = {
    "fixed_overhead_lut": 29_700,   # 非 MAC 固定开销（FSM/仲裁/FIFO 等），independent-stack §3.6 口径
    "lane_lut_pure_lut":  12,       # 口径 A：纯 mxfp4 乘核查表（不含累加器/接口）§3.6
    "lane_lut_full":      90,       # 口径 B：完整 lane（查表+移位加法+累加器）simd_mac_array.v 注释
    "lane_lut_full_acc16": 54,      # 口径 B'：完整 lane + ACC16 累加器（-40%，simd 注释余量①）
    "bf16_lut_per_mac":   150,      # bf16 整 MAC 的 LUT 成本（§3.5 表）
    "dsp_per_bf16_mac":   1,        # bf16 需要 1 DSP/通道
}

# ═══════════════════════ 2b. 图执行器（泛化控制面）成本模型 ════════════════════
# 泛化 = 把「写死单模型的 FSM」换成「指令驱动的数据流调度器」。
# 固定开销从 ~29,700（写死FSM）涨到图执行器；每多一项通用性 = 多一截解码/调度逻辑。
# ⚠️ 出处诚实标注: 下表为「按 simd_mac_array.v 同类控制逻辑经验」的 3× 假设区间，
#    非实测 —— 需要 RTL 综合后才钉死。数值取乐观/中估/悲观三行, 结论条用中估。
GRAPH = {
    "fsm_k3_lut":          29_700,  # 原固定开销：只跑 K3 的 FSM（simd_mac_array 累计）
    # 图执行器新增组件（都是「读指令→分发→等完成」的通用骨架，与具体模型无关）
    # 每项 = [乐观, 中估, 悲观]，来源: lane LUT 12/54/90 的换算孔径(每 lane 含控制器~2-4%)
    "instr_fetch_decode":   [4_000,  6_000,  10_000],  # 指令取指/解码（定长指令字）
    "scheduler_queues":     [5_000,  8_000,  14_000],  # 就绪队列 + 优先级仲裁
    "tensor_addr_engine":   [3_000,  5_000,   9_000],  # 维度→地址生成
    "obj_registers":        [2_000,  3_000,   5_000],  # 模型描述表缓存读口
    "overlay_mux":          [1_000,  1_500,   2_500],  # 算子结果回写路选
    "per_op_lut":           [  40,    120,     300],   # 每算子解码分支
    "ops_k3_core":             8,   # K3 需要的核心算子集（GEMV/Router-GEMV/ROPE/
                                     #   SiTU-GLU/RRMSNorm/Dequant/KV-save/KV-load）
}
GRAPH_MODE = "mid"   # 用乐观/中估/悲观哪一列: opt/mid/pes

def graph_lut_item(key):
    """取值并标注来源区间。key 是 GRAPH 里的数组项名。"""
    v = GRAPH[key]
    if isinstance(v, list):
        idx = {"opt": 0, "mid": 1, "pes": 2}[GRAPH_MODE]
        return v[idx]
    return v

def graph_engine_lut(n_core_ops, n_extra_ops=0):
    """图执行器固定开销（按 GRAPH_MODE 取 opt/mid/pes 一列）。"""
    fixed = (graph_lut_item("instr_fetch_decode") + graph_lut_item("scheduler_queues")
             + graph_lut_item("tensor_addr_engine") + graph_lut_item("obj_registers")
             + graph_lut_item("overlay_mux"))
    per = graph_lut_item("per_op_lut") * (n_core_ops + n_extra_ops)
    return dict(fixed=fixed, per_op=per, total=fixed+per)

# ═══════════════════════ 3. K3-MoE 流量账（k3-verdict 实测）═══════════════════
# 2026-08-29 修正④：trunk 保留 fp16 → 108.8GB/pass（原始字节），不再是量化 36GB。
# 专家层仍 mxfp4 落盘 → 25.83 GB/token。
K3_TRAFFIC = {
    "experts_mxfp4_gb_per_token": 25.83,   # top-16×92×17.55MB，磁盘实搬字节
    "trunk_fp16_gb_per_pass": 108.8,       # trunk fp16 全读（原始精度，保精决定）
    "top_k": 16,
    "layers": 92,
}

# ═══════════════════════ 4. 链路算式 ═══════════════════════════════════════════
def dram_bw_gbs():
    return FPGA["dram_bus_bits"] / 8 * FPGA["dram_mts"] / 1_000

def dram_bw_real_gbs():
    return dram_bw_gbs() * 0.8

def pcie_bw_gbs():
    """PCIe Gen3 每 lane 8GT/s ≈ 0.985 GB/s 有效；x4 → ~3.94 GB/s (理论编码前为 8GT/s×4/8)。
    实际取 ~2.8 GB/s 保守值（Gen3 x4 常见实测，含协议开销/丢包）。"""
    return FPGA["pcie_lanes_used"] * 0.985 * 0.75   # ≈2.95 GB/s

def host_nand_bw_gbs():
    """主机侧 NAND 源能力：SATA SSD ~0.5、NVMe ~2-3 GB/s；HDD 实测 0.072 GB/s。
    默认 NVMe SSD（推理机常见）。"""
    return 2.0

def link_bottleneck():
    """整链瓶颈：min(主机NAND, PCIe, DDR3)，单位 GB/s"""
    return min(host_nand_bw_gbs(), pcie_bw_gbs(), dram_bw_gbs())

def bytes_per_token_gb(trunk_resident=True):
    """每 token 需从主机流入的字节。
    trunk_resident=True : trunk 常驻 DDR3，只流专家 25.83GB
    trunk_resident=False: trunk 也全从主机流 → +108.8GB
    """
    if trunk_resident:
        return K3_TRAFFIC["experts_mxfp4_gb_per_token"]
    return K3_TRAFFIC["experts_mxfp4_gb_per_token"] + K3_TRAFFIC["trunk_fp16_gb_per_pass"]

def tps_from(bw, bytes_per_token_gb):
    return bw / bytes_per_token_gb

def lut_pct(lut):
    return lut / FPGA["lut"] * 100

def dsp_pct(dsp):
    return dsp / FPGA["dsp"] * 100

# ═══════════════════════ 5. 精度分裂的资源占用 ════════════════════════════════
# 专家：mxfp4 查表 SIMD；trunk：bf16 通道（fp16 保留）
def split_occupancy(n_expert_lane, n_trunk_mac):
    """按 专家lane数(查表) + trunk MAC数(bf16) 算 LUT/DSP。"""
    mac_lut_expert = n_expert_lane * COMPONENT["lane_lut_pure_lut"]
    mac_lut_trunk  = n_trunk_mac  * COMPONENT["bf16_lut_per_mac"]
    dsp_trunk      = n_trunk_mac  * COMPONENT["dsp_per_bf16_mac"]
    tot_lut = mac_lut_expert + mac_lut_trunk + COMPONENT["fixed_overhead_lut"]
    return dict(expert_lane=n_expert_lane, trunk_mac=n_trunk_mac,
                expert_lut=mac_lut_expert, trunk_lut=mac_lut_trunk,
                dsp=dsp_trunk, total_lut=tot_lut,
                lut_pct=tot_lut/FPGA["lut"]*100, dsp_pct=dsp_trunk/FPGA["dsp"]*100)

def main():
    print("=" * 76)
    print(f"Tang Mega 138K Pro 资源占用计算器（v2 · 精度分裂 + 链路瓶颈修正）")
    print(f"  官方基线: {FPGA['name']}")
    print(f"  LUT {FPGA['lut']:,} / DSP {FPGA['dsp']} / B-SRAM {FPGA['bsram_kbit']/8:.0f}KB")
    print(f"  DDR3: {FPGA['dram_bus_bits']}-bit × {FPGA['dram_mts']}MT/s = "
          f"{dram_bw_gbs():.2f} GB/s 理论 / {dram_bw_real_gbs():.2f} GB/s 实测")
    print(f"  PCIe Gen{FPGA['pcie_gen']} ×{FPGA['pcie_lanes_used']} ≈ {pcie_bw_gbs():.2f} GB/s（保守 0.75 效）")
    print(f"  主机 NAND（NVMe SSD 默认）≈ {host_nand_bw_gbs():.1f} GB/s")
    print("=" * 76)

    # ── A. 整链带宽瓶颈 ──
    print("\n" + "─" * 76)
    print("A. 整链带宽瓶颈（min 规则，修正①）")
    print("─" * 76)
    srcs = [("主机 NAND", host_nand_bw_gbs(), "NVMe SSD 默认 2.0；HDD 实测 0.072"),
            ("PCIe Gen3×4", pcie_bw_gbs(), "x4 有效~2.95GB/s，保守再乘 0.75"),
            ("板上 DDR3", dram_bw_gbs(), "32-bit×1333 理论峰值")]
    for name, bw, note in srcs:
        print(f"  {name:12s}: {bw:6.2f} GB/s   ({note})")
    btl = link_bottleneck()
    print(f"  ─────────────────────────────")
    print(f"  ⇒ 链路瓶颈 = min(...) = {btl:.2f} GB/s")
    print(f"  ⇒ DDR3 5.33 从未是瓶颈：上游 PCIe {pcie_bw_gbs():.2f} 已把它盖住。")

    # ── B. 流量账（trunk fp16 修正④）──
    print("\n" + "─" * 76)
    print("B. K3 每 token 流量账（trunk fp16 保留）")
    print("─" * 76)
    print(f"  专家（mxfp4 落盘）: {K3_TRAFFIC['experts_mxfp4_gb_per_token']} GB/token")
    print(f"  trunk（fp16 保留）: {K3_TRAFFIC['trunk_fp16_gb_per_pass']} GB/pass（每 token 全读）")
    for res in (True, False):
        b = bytes_per_token_gb(res)
        n = "trunk 常驻 DDR3" if res else "trunk 也流式"
        print(f"  [{n}] 每 token {b:.1f} GB → 链路吞吐 {tps_from(btl, b):.3f} t/s")

    # ── C. 精度分裂资源占用（修正② + ③）──
    print("\n" + "─" * 76)
    print("C. 精度分裂面积（专家 int4 查表 + trunk fp16 bf16 通道）")
    print("─" * 76)
    print("  SIMD×4 只省乘法不省加法（修正③）：完整 lane 含累加器/归约树。")
    print("  trunk fp16 是实数乘累加 → 无 256 组合查表 → 走 bf16/DSP（修正②）。\n")
    for name, ne, nt in [("原 128 MAC（全 bf16）", 0, 128),
                         ("mxfp4-SIMD 512 路 + trunk 128 bf16", 512, 128)]:
        r = split_occupancy(ne, nt)
        print(f"  {name}:")
        print(f"    专家 {r['expert_lane']} lane×12 = {r['expert_lut']:,} LUT  |  "
              f"trunk {r['trunk_mac']}×150 = {r['trunk_lut']:,} LUT  |  "
              f"DSP {r['dsp']}（{r['dsp_pct']:.0f}%）")
        print(f"    LUT 合计 {r['total_lut']:,} = {r['lut_pct']:.1f}%（含固定 {COMPONENT['fixed_overhead_lut']:,}）")

    # ── D. 原 §3.5 表对照（含 trunk 修正前）──
    print("\n" + "─" * 76)
    print("D. 与文档 §3.5 表对照（历史口径，trunk 混入 mxfp4）")
    print("─" * 76)
    print("  文档 mxfp4-SIMD 512 路「DSP 0%」是把 trunk 也当 int4 的乐观值。")
    print("  修正后 trunk fp16 必须占 bf16 通道 → DSP 不再 0%，LUT 也需重排。")

    # ── E. 极限压榨（全部 LUT 换 lane，两种口径）──
    print("\n" + "─" * 76)
    print("E. 极限压榨：逻辑 lane 上限")
    print("─" * 76)
    avail = FPGA["lut"] - COMPONENT["fixed_overhead_lut"]
    for nm, cost in [("乘核 A 12", COMPONENT["lane_lut_pure_lut"]),
                     ("完整lane B 90", COMPONENT["lane_lut_full"]),
                     ("lane+ACC16 54", COMPONENT["lane_lut_full_acc16"])]:
        lanes = avail // cost
        # 若留 trunk bf16 通道则扣除
        trk = 128 * COMPONENT["bf16_lut_per_mac"]
        lanes_ex = (avail - trk) // cost
        print(f"  {nm:16s}: 全换 {lanes:,} lane ;  留 trunk 128 bf16 后剩 {lanes_ex:,} lane")

    # ── F. 结论 ──
    print("\n" + "─" * 76)
    print("结论")
    print("─" * 76)
    b = bytes_per_token_gb(trunk_resident=True)
    print(f"  真实上限（专家常驻 DDR3）: min(链路 {btl:.2f}, {b:.1f}GB/token) = "
          f"{tps_from(btl, b):.3f} t/s")
    b2 = bytes_per_token_gb(trunk_resident=False)
    print(f"  trunk 也流式:              min(链路 {btl:.2f}, {b2:.1f}GB/token) = "
          f"{tps_from(btl, b2):.3f} t/s")
    print(f"  ⇒ 逻辑不是瓶颈（C 段 LUT≈<40%）；带宽链（主机NAND→PCIe→DDR3）才是。")
    print(f"  ⇒ 138K 真实可达 < 0.1 t/s，只能当链路/逻辑验证平台。")

    # ── G. 图执行器（泛化控制面）资源账 ──
    print("\n" + "─" * 76)
    print("G. 图执行器 RTL: 泛化换模型的资源账 (把 FSM 换成指令驱动调度器)")
    print("─" * 76)
    print(f"  原 K3 写死 FSM 固定开销:        {GRAPH['fsm_k3_lut']:,} LUT")
    print(f"  图执行器固定开销 (读指令→调度→发MAC) [Graph mode={GRAPH_MODE}, 假设区间见 GRAPH dict]:")
    print(f"    指令取指/解码                {graph_lut_item('instr_fetch_decode'):,}")
    print(f"    调度队列/仲裁                {graph_lut_item('scheduler_queues'):,}")
    print(f"    张量地址生成                  {graph_lut_item('tensor_addr_engine'):,}")
    print(f"    模型描述表缓存口              {graph_lut_item('obj_registers'):,}")
    print(f"    算子结果回写路选              {graph_lut_item('overlay_mux'):,}")
    fixed_graph = (graph_lut_item("instr_fetch_decode") + graph_lut_item("scheduler_queues")
                   + graph_lut_item("tensor_addr_engine") + graph_lut_item("obj_registers")
                   + graph_lut_item("overlay_mux"))
    print(f"    小计                         {fixed_graph:,} LUT")
    print(f"    + 每算子解码分支              {graph_lut_item('per_op_lut')}/算子 (乐观{GRAPH['per_op_lut'][0]} / 悲观{GRAPH['per_op_lut'][2]})")
    ops_add = GRAPH["ops_k3_core"] + 2   # +Router/GEMV/Dequant 各算通用算子
    core_g = graph_engine_lut(ops_add)
    print(f"  [仅覆盖 K3 核心算子 {ops_add} 种] 合计 "
          f"{core_g['total']:,} LUT = {lut_pct(core_g['total']):.1f}%")
    # 扩展不同模型覆盖
    for label, extra in [("+Qwen/LLaMA dense (~12 算子)", 4),
                         ("+混入 Mamba/SSM (~14 算子)", 6),
                         ("+多模态/视觉后端 (~16 算子)", 8)]:
        r = graph_engine_lut(ops_add, extra)
        print(f"  {label:30s} = {r['total']:5,} LUT "
              f"(固定{fixed_graph:,} + 算子{r['per_op']:,}) = {lut_pct(r['total']):.1f}%")
    diff = core_g["total"] - GRAPH["fsm_k3_lut"]
    if diff >= 0:
        print(f"\n  泛化代价 (图执行器 − 写死FSM) = +{diff:,} LUT "
              f"(+{lut_pct(diff):.1f}个百分点)")
    else:
        print(f"\n  泛化反而省 {abs(diff):,} LUT "
              f"(-{lut_pct(abs(diff)):.1f}个百分点): 通用调度器固定开销 < 专用FAM映射")
    print(f"  交换: 换模型从「重烧位流/重综合」→「换 DDR3 模型描述表」.")

    # ── H. 图执行器 × MAC 面积联合 ──
    print("\n" + "─" * 76)
    print("H. 图执行器 × lane 联合占用 (推理引擎合体够不够 138K)")
    print("─" * 76)
    avail = FPGA["lut"]
    for name, mac_lut, nmac in [("mxfp4 乘核 A (12/lane)", 12, 128),
                                ("完整 lane B (90/lane)",   90, 128),
                                ("bf16 MAC (150/MAC)",    150,  64)]:
        left = avail - core_g["total"] - mac_lut * nmac
        # 若 trunc 走 bf16 通道另扣
        left_no_trunk = left - 0
        print(f"  {name:28s} × {nmac:3d}: 图执行器{core_g['total']:,} + "
              f"{mac_lut*nmac:,} = {core_g['total']+mac_lut*nmac:,} "
              f"({lut_pct(core_g['total']+mac_lut*nmac):.0f}%), 剩 {left_no_trunk:,} LUT")

if __name__ == "__main__":
    main()