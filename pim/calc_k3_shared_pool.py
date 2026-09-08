#!/usr/bin/env python3
"""
K3 共享池架构 · 真实 BOM + 吞吐
2026-09-07 定案：226GB 共享 LPDDR5X 池，224颗子计算单元共享
对比旧假设（128GB/颗 × ¥8/GB 便宜内存口径）
"""
# ===== K3 实测参数 (k3-verdict.md + MoE-token-speed.md + K3_MXFP8_ENTROPY.md) =====
K3_EXPERT_PER_TOKEN_GB = 25.83   # 92层×16experts×17.55MB
K3_TRUNK_PER_TOKEN_GB  = 55.6    # MXFP8 trunk（trunk_mxfp8.bin 55.6GB, 1.92x压缩，每token全读）
K3_TOTAL_PER_TOKEN_GB  = K3_EXPERT_PER_TOKEN_GB + K3_TRUNK_PER_TOKEN_GB  # 81.43

# ===== 共享池容量（--pool 可调） =====
POOL_GB        = 192.0   # 用户主配置: 192GB = trunk 55.6 + 专家 136GB
TRUNK_GB       = 55.6    # MXFP8 trunk 驻留
EXPERT_POOL_GB = POOL_GB - TRUNK_GB

# ===== 芯片参数 (calculation-formulas.md) =====
N_CHIPS        = 224
MAC_PER_CHIP   = 128
CLOCK_GHZ      = 1.0      # 满档（prefill/突发）
DIE_COST       = 91       # 14nm die+封装+PHY（量产）

# ===== 用户可调频率 (超频) =====
import argparse, math
_p = argparse.ArgumentParser(description="K3 共享池：两墙模型（LPDDR带宽×PCIe补miss）× 突变点")
_p.add_argument("--freq", type=float, default=None, nargs="+",
                help="MAC 频率 GHz。默认 = DRAM 匹配档（~0.134，省电）；"
                     "超频示例: --freq 0.5 / 1.0 可对比满档")
_p.add_argument("--pool", type=float, default=192.0,
                help="共享池容量 GB（默认 192 = trunk 55.6 + 专家 136）")
_p.add_argument("--pcie", type=float, default=60.0,
                help="补 miss 的 PCIe 带宽 GB/s（默认 60 ≈ Gen5；Gen4≈30）")
_p.add_argument("--scan", action="store_true",
                help="扫容量找突变点（两墙交叉 → 吞吐台阶）")
_p.add_argument("--tps", type=float, default=None,
                help="目标吞吐 t/s → 反推组件清单（MAC颗数/LPDDR容量/PCIe/硬盘）")
_p.add_argument("--bom", action="store_true",
                help="按 每token成本 目标推出 个人/数据中心 BOM 清单")
_p.add_argument("--tokcost", type=float, default=3e-5,
                help="每 token 成本上限 ¥(单位µ, 默认 30µ=0.003厘, 摊销+电费)")
_p.add_argument("--util", type=float, default=None,
                help="卡利用率 (默认: personal=0.25, dc=0.85)")
_p.add_argument("--life", type=float, default=None,
                help="设备寿命年 (默认: personal=5, dc=3)")
_p.add_argument("--elec", type=float, default=0.6,
                help="电价 ¥/kWh (默认 0.6)")
_p.add_argument("--die", type=str, default="8,16,32",
                help="LPDDR 颗粒容量档位 GB，逗号分隔（默认 8,16,32 三档枚举）；"
                     "注意带宽=颗数×171 与颗粒容量无关，大颗粒省颗数但失带宽，"
                     "8GB 颗粒通常是带宽约束下的最优档")
_p.add_argument("--noise", action="store_true",
                help="输出噪音估算（风冷 dBA，功耗/Pf模型）")
args = _p.parse_args()
DIED_OPTS = [float(x) for x in args.die.split(",") if float(x) >= 2]
POOL_GB = args.pool
EXPERT_POOL_GB = POOL_GB - TRUNK_GB

# ===== 专家命中率模型 (lpddr-resident-architecture.md 表) =====
# 专家池预算GB -> 命中%：9->18, 41->51, 73->67, 105->82, 145->97, 171->100
# ⚠ 待真机验证：此表源于 fixtures 合成 trace, PC 真机长 trace (--gen 32+) 未回,
#   容量拐点/命中曲线可能偏移（见 HANDOFF 待办10修正块）。当前为设计参考。
_HIT = [(9,18),(41,51),(73,67),(105,82),(145,97),(171,100)]
def hit_rate(exp_gb):
    if exp_gb >= _HIT[-1][0]: return 100.0
    if exp_gb <= _HIT[0][0]:  return _HIT[0][1]
    for (a,ha),(b,hb) in zip(_HIT,_HIT[1:]):
        if a <= exp_gb <= b:
            return ha + (hb-ha)*(exp_gb-a)/(b-a)
    return 100.0

# ===== 两墙模型 =====
def walls(pool_gb, pcie_bw):
    """返回 (LPDDR带宽限t/s, PCIe补miss限t/s, 命中率)
    LPDDR限: 池带宽/(trunk+专家×命中)  —— 热读喂 MAC
    PCIe限 : pcie/(专家×(1-命中))       —— 冷专家实时补
    实际吞吐 = min(两墙)"""
    n_dies = pool_gb / MEM_GB_PER_DIE
    pool_bw = n_dies * BWS_PER_DIE
    h = hit_rate(pool_gb - TRUNK_GB) / 100.0
    t_ldd = pool_bw / (K3_TRUNK_PER_TOKEN_GB + K3_EXPERT_PER_TOKEN_GB*h)
    miss_pt = K3_EXPERT_PER_TOKEN_GB * (1-h)
    t_pcie = pcie_bw / miss_pt if miss_pt > 1e-6 else 1e9
    return t_ldd, t_pcie, h*100

K3_MAC_PER_TOKEN = 1.12e11   # 每token MACs（trunk 1.48e10 + 专家 9.72e10）
TOTAL_MAC = N_CHIPS * MAC_PER_CHIP

# ===== 内存参数 =====
LPDDR_PRICE_OLD = 8       # ¥/GB（旧便宜假设）
LPDDR_PRICE_NEW = 60      # ¥/GB（LPDDR5X 实际）
LPDDR_PER_CHIP_OLD = 128  # GB（旧：每颗独立128GB）
MEM_GB_PER_DIE  = 8        # GB（新：共享池 226GB = 28颗 8GB）
N_MEM_DIES      = POOL_GB / MEM_GB_PER_DIE

# ===== 带宽计算 =====
BWS_PER_DIE = 171.0        # 8ch LPDDR5X GB/s
POOL_BW     = N_MEM_DIES * BWS_PER_DIE
H200_BW     = 4800.0

# ===== 吞吐（两墙模型）=====
T_LDD, T_PCIE, HIT_PCT = walls(POOL_GB, args.pcie)
TPS_K3      = min(T_LDD, T_PCIE)          # 实际 = min(池带宽, PCIe补miss)
TPS_H200    = H200_BW / K3_TOTAL_PER_TOKEN_GB

# ===== 频率匹配档（DRAM 瓶颈 → MAC 降到刚好够吃的频率）=====
F_MATCH_GHZ = TPS_K3 * K3_MAC_PER_TOKEN / (TOTAL_MAC * 1e9)   # GHz

def calc_power(freq_ghz):
    """对齐 calc_performance.py 功耗模型（单颗）：
       MAC_POWER=38W@1GHz(f³) + 漏电2W + SRAM2 + SerDes2 + 其他1 = 静态7W
       动态随频率降, 静态(漏电)不降"""
    mac_dyn = 38.0 * N_CHIPS * (freq_ghz / 1.0) ** 3
    static = (2 + 2 + 2 + 1) * N_CHIPS
    return mac_dyn + static

# ===== 成本 =====
# 旧口径（每颗独立含内存）
old_mem_total = N_CHIPS * LPDDR_PER_CHIP_OLD * LPDDR_PRICE_OLD
old_chip_cost = N_CHIPS * (DIE_COST + LPDDR_PER_CHIP_OLD * LPDDR_PRICE_OLD + 59)  # +杂费凑1174
old_total     = old_chip_cost

# 新口径（共享池）
new_mem_cost  = POOL_GB * LPDDR_PRICE_NEW
new_chip_cost = N_CHIPS * DIE_COST
new_pcb       = 800
new_total     = new_chip_cost + new_mem_cost + new_pcb

# ===== 输出 =====
print("=" * 70)
print("K3 共享池架构 · 真实 BOM + 吞吐 对照")
print("=" * 70)

print(f"\n--- K3 模型 (trunk 用 MXFP8 55.6GB) ---")
print(f"  专家/token : {K3_EXPERT_PER_TOKEN_GB} GB")
print(f"  trunk/token: {K3_TRUNK_PER_TOKEN_GB} GB")
print(f"  合计/token : {K3_TOTAL_PER_TOKEN_GB} GB")

print(f"\n--- 共享池 {POOL_GB:.0f}GB (trunk {TRUNK_GB:.0f} + 专家池 {EXPERT_POOL_GB:.0f}) ---")
print(f"  形态: {N_MEM_DIES:.0f}颗 {MEM_GB_PER_DIE}GB LPDDR5X")
print(f"  池带宽: {N_MEM_DIES:.0f}×{BWS_PER_DIE:.0f} = {POOL_BW:,.0f} GB/s")
print(f"  命中率: 专家池 {EXPERT_POOL_GB:.0f}GB → {HIT_PCT:.0f}%（工作集命中）")

print(f"\n--- 两墙模型 (四路带宽分解) ---")
hit = HIT_PCT/100.0
miss_pt = K3_EXPERT_PER_TOKEN_GB * (1-hit)
print(f"  ① MAC吞  : {TPS_K3*K3_TOTAL_PER_TOKEN_GB:,.0f} GB/s = {K3_TOTAL_PER_TOKEN_GB:.1f}GB × {TPS_K3:.1f}t/s")
print(f"  ② 热读LPDDR: {TPS_K3*(K3_TRUNK_PER_TOKEN_GB + K3_EXPERT_PER_TOKEN_GB*hit):,.0f} GB/s  ← 池带宽喂 MAC")
print(f"  ③ 补missPCIe: {TPS_K3*miss_pt:,.0f} GB/s ← {miss_pt:.2f}GB/token冷专家 从 PCIe({args.pcie:.0f}) 实时补")
print(f"  ④ 冷灌入: 一次性 {POOL_GB:.0f}GB / Gen5≈{args.pcie:.0f}GB/s ≈ {POOL_GB/args.pcie:.0f}s（工作集切换时）")

print(f"\n--- 吞吐（两墙取 min）---")
print(f"  LPDDR 限: {T_LDD:,.1f} t/s  (池带宽/热读)")
print(f"  PCIe 限 : {T_PCIE:,.1f} t/s  (补miss带宽/miss流量)")
print(f"  K3 实际 : {TPS_K3:.1f} t/s  ← min(两墙), 瓶颈={'PCIe补miss' if T_PCIE<T_LDD else 'LPDDR池带宽'}")
print(f"  H200 单卡: {TPS_H200:.1f} t/s")
print(f"  相对    : {TPS_K3/TPS_H200:.2f}x")

if args.bom:
    print(f"\n{'='*70}")
    print(f"按每token成本 ≤ ¥{args.tokcost*1e6:.0f}µ 推 BOM（摊销+电费）")
    print(f"{'='*70}")
    # 每 token 成本 = 摊销(整机价/寿命内token数) + 电费(功率/吞吐 × 电价)
    # token 数 = 吞吐×秒×利用率；摊销 = 价 / (t/s×寿命秒×利用率)
    HOURS = 365*24*3600
    K3_MAC = K3_MAC_PER_TOKEN

    def cost_per_token(total_cost, tps, watts, util, life_y):
        life_s = life_y * HOURS
        amort   = total_cost / (tps * life_s * util)
        energy  = watts / tps * args.elec / 3.6e6        # W×s/token → kWh
        return amort + energy, amort, energy

    # 扫描组合空间：MAC颗数(经济档) × (LPDDR容量, 颗粒档位) × PCIe档
    # 颗粒档位: 每档 8/16/32GB 离散; 带宽 = 颗数×171(颗定带宽), 与档位无关
    # 噪音模型(风冷): 功耗→dBA 近似 Pf曲线 (TDP 越大越吵)
    def noise_dba(watts, liquid=False):
        if liquid: return 22.0                      # 液冷: 泵+低噪风扇, 恒定
        return 15 + 18 * math.log10(max(watts,1))   # 风冷: 对数模型
    def dies_for(pool_gb, die_gb):
        return max(1, math.ceil(pool_gb / die_gb))
    def bw_for(dies, die_gb):
        return dies * BWS_PER_DIE

    def design_bom(n_chips, pool_gb, pcie_bw, die_gb=8.0):
        dies = dies_for(pool_gb, die_gb)
        bw = bw_for(dies, die_gb)
        h = hit_rate(pool_gb - TRUNK_GB) / 100.0
        miss_pt = K3_EXPERT_PER_TOKEN_GB * (1-h)
        t_ldd  = bw / (K3_TRUNK_PER_TOKEN_GB + K3_EXPERT_PER_TOKEN_GB*h)
        t_pcie = pcie_bw / miss_pt if miss_pt > 1e-6 else 1e9
        t_mac  = n_chips * MAC_PER_CHIP * 1e9 / K3_MAC   # 满档算力
        tps = min(t_ldd, t_pcie, t_mac)
        # 匹配档频率（够吃 tps 即可）
        f_match = tps * K3_MAC / (n_chips * MAC_PER_CHIP * 1e9)
        mac_dyn = 38.0 * n_chips * max(f_match, 0.01)**3
        watts  = mac_dyn + (2+2+2+1)*n_chips
        cost   = n_chips*DIE_COST + pool_gb*LPDDR_PRICE_NEW + new_pcb
        return tps, watts, cost, h, dies

    # 个人用户：桌面单卡 —— 满足成本约束下, 取"性价比最优"（每元买到的 t/s 最高, 且整机可负担）
    # 噪音：个人愿为静音买单 → 给出 风冷/液冷 两档（液冷+¥3000, dBA降~20）
    print(f"\n--- 场景A 个人用户 (单卡, 利用率25%, 寿命5年, Gen5×16=64GB/s) ---")
    util = args.util if args.util else 0.25
    life = args.life if args.life else 5.0
    cands_p = []
    for n in range(16, 225, 16):
        for pg in range(64, 233, 8):
            for die_gb in DIED_OPTS:
                tps, watts, cost, h, dies = design_bom(n, pg, 64, die_gb)
                cp, am, en = cost_per_token(cost, tps, watts, util, life)
                if tps >= 5 and cp <= args.tokcost:
                    cands_p.append((round(cp,12), n, pg, tps, watts, cost, h, die_gb, dies, am, en))
    if cands_p:
        cp, n, pg, tps, watts, cost, h, die_gb, dies, am, en = max(cands_p, key=lambda r: r[3]/r[5])  # t/s per ¥
        print(f"  性价比解: {n}颗MAC + {pg:.0f}GB池({dies}颗{die_gb:.0f}GB), 命中{h*100:.0f}%")
        print(f"  吞吐 {tps:.1f} t/s | 功耗 {watts:.0f}W | 整机 ¥{cost/1e4:.1f}万")
        if args.noise:
            print(f"  噪音: 风冷 ≈{noise_dba(watts):.0f} dBA | 液冷 ≈{noise_dba(watts,True):.0f} dBA "
                  f"(液冷+¥3000 → 个人静音项)")
        print(f"  每token: 摊销 ¥{am*1e4:.2f}万元/万token ≈ ¥{am*1e6:.1f}µ/千token | 电费 ¥{en*1e6:.1f}µ")
        print(f"  合计 ¥{cp*1e6:.1f}µ/token (限 ¥{args.tokcost*1e6:.0f}µ)  ✅")
    else:
        print(f"  ✗ 无解: 每token成本限 ¥{args.tokcost:.4f} 太紧（改高或降需求）")

    # 数据中心：多卡阵列 —— 满足成本约束下, 取"单卡摊销最低 + 吞吐够大"配置
    # 噪音对机房不重要, 但功耗决定散热成本
    print(f"\n--- 场景B 数据中心 (机架阵列, 利用率85%, 寿命3年, Gen5×32=128GB/s) ---")
    util = args.util if args.util else 0.85
    life = args.life if args.life else 3.0
    cands_d = []
    for n in range(16, 225, 16):
        for pg in range(64, 233, 8):
            for die_gb in DIED_OPTS:
                tps, watts, cost, h, dies = design_bom(n, pg, 128, die_gb)
                cp, am, en = cost_per_token(cost, tps, watts, util, life)
                if tps >= 20 and cp <= args.tokcost:
                    cands_d.append((round(cp,12), n, pg, tps, watts, cost, h, die_gb, dies, am, en))
    if cands_d:
        cp, n, pg, tps, watts, cost, h, die_gb, dies, am, en = min(cands_d, key=lambda r: r[0])  # 最低单token成本
        gpu_per_k = math.ceil(1000/tps)   # 1000t/s 需卡数
        print(f"  单卡最优: {n}颗MAC + {pg:.0f}GB池({dies}颗{die_gb:.0f}GB), 命中{h*100:.0f}%")
        print(f"  单卡吞吐 {tps:.1f} t/s | 功耗 {watts:.0f}W | 单卡 ¥{cost/1e4:.1f}万")
        if args.noise:
            print(f"  噪音(机房忽略): 风冷 ≈{noise_dba(watts):.0f} dBA | 集中水冷 ≈22 dBA（数据中心常态）")
        print(f"  每token: 摊销 ¥{am*1e6:.1f}µ | 电费 ¥{en*1e6:.1f}µ | 合计 ¥{cp*1e6:.1f}µ")
        print(f"  集群规模 (1000 t/s)：{gpu_per_k} 卡 ≈ ¥{cost*gpu_per_k/1e4:.0f}万, "
              f"{watts*gpu_per_k/1000:.0f} kW")
    else:
        print(f"  ✗ 无解: 每token成本限 ¥{args.tokcost:.4f} 太紧")

    print(f"\n  注: 摊销假设利用率{util:.0%}×寿命{life:.0f}年；电价¥{args.elec}/kWh 可--elec调；"
          f"命中率表为fixtures口径待真机验证；"
          f"颗粒档 {args.die}GB（大颗粒省颗数但带宽同比例降, 性能折损）")

if args.tps:
    TGT = args.tps
    print(f"\n--- 目标 {TGT:.1f} t/s → 组件清单反推 ---")

    # ① MAC 颗数：算力 = 目标 × 每token MAC；每颗 128 MAC @freq
    need_tmac = TGT * K3_MAC_PER_TOKEN / 1e12           # TMAC/s
    n_chips = math.ceil(need_tmac * 1e12 / (MAC_PER_CHIP * 1e9 * (args.freq[0] if args.freq else 1.0)))
    n_chips = max(n_chips, 1)
    print(f"  ① MAC      : 需 {need_tmac:.1f} TMAC/s → {n_chips} 颗 × {MAC_PER_CHIP} MAC "
          f"({n_chips*MAC_PER_CHIP:,} MAC)")
    print(f"                满档 {n_chips*MAC_PER_CHIP*(args.freq[0] if args.freq else 1.0)/1e3:.0f} TMAC/s "
          f"≧ {need_tmac:.1f} ✅")

    # ② LPDDR 容量（含命中率→容量反查）：
    #    目标吞吐必须同时满足两墙 → 找最小池容量使 min(墙) ≥ 目标
    print(f"  ② LPDDR    : 按命中率表反查 专家池→容量, 要求池带宽与PCIe都 ≥ 目标")
    found = None
    for exp_gb in range(0, 200, 2):
        pool = TRUNK_GB + exp_gb
        dies = math.ceil(pool / MEM_GB_PER_DIE)
        bw = dies * BWS_PER_DIE
        h = hit_rate(exp_gb) / 100.0
        miss_pt = K3_EXPERT_PER_TOKEN_GB * (1-h)
        t_ldd = bw / (K3_TRUNK_PER_TOKEN_GB + K3_EXPERT_PER_TOKEN_GB*h)
        t_pcie = args.pcie / miss_pt if miss_pt > 1e-6 else 1e9
        if min(t_ldd, t_pcie) >= TGT:
            found = (exp_gb, pool, dies, h, t_ldd, t_pcie, miss_pt)
            break
    if found:
        exp_gb, pool, dies, h, t_ldd, t_pcie, miss_pt = found
        print(f"                专家池 {exp_gb}GB + trunk {TRUNK_GB} = {pool}GB → {dies} 颗 8GB")
        print(f"                带宽 {dies}×{BWS_PER_DIE} = {bw:,.0f} GB/s, 命中 {h*100:.0f}%")
        print(f"                LPDDR限 {t_ldd:.1f} / PCIe限 {t_pcie:.1f} → min {min(t_ldd,t_pcie):.1f} ✅")
    else:
        print(f"                ✗ 扫到 200GB 专家池仍不够 → 需更大池或更高 PCIe")

    # ③ PCIe
    miss_bw = TGT * miss_pt if found else 0
    print(f"  ③ PCIe     : 需补 miss {miss_bw:,.0f} GB/s (miss {miss_pt:.2f}GB/token × {TGT}t/s)")
    for name, bw in [("Gen4×16",32),("Gen5×16",64),("Gen5×32",128)]:
        mark = "✅" if bw >= miss_bw*1.05 else ("⚠" if bw >= miss_bw else "✗")
        print(f"                {name}: {bw}GB/s {mark}")

    # ④ 硬盘（冷灌入/工作集切换）
    print(f"  ④ 硬盘     : 专家全量 82,432对×17.55MB ≈ 1413GB; 需 ≥ 池容量持续喂")
    print(f"                冷灌入 {pool:.0f}GB / Gen5≈{args.pcie}GB/s ≈ {pool/args.pcie:.0f}s")

    # ⑤ 成本
    mem_cost = pool * LPDDR_PRICE_NEW
    chip_cost = n_chips * DIE_COST
    tot_cost = chip_cost + mem_cost + new_pcb
    print(f"  ⑤ 成本     : {n_chips}颗×¥{DIE_COST}=¥{chip_cost:,} + {pool:.0f}GB×¥{LPDDR_PRICE_NEW}=¥{mem_cost:,} + PCB ¥{new_pcb:,}")
    print(f"                合计 ¥{tot_cost:,.0f} = {tot_cost/1e4:.1f}万")
    print(f"                每token成本效率: ¥{tot_cost/TGT:,.0f}/t/s")

if args.scan:
    print(f"\n--- 突变点扫描 (池容量→吞吐台阶, PCIe={args.pcie:.0f}GB/s) ---")
    print(f"  {'池GB':>5} {'专家G':>5} {'命中%':>5} {'LPDDR限':>7} {'PCIe限':>7} {'实际':>6} {'突变?'}")
    prev = None
    rows = []
    for pg in range(64, 234, 8):
        t_ldd, t_pcie, h = walls(pg, args.pcie)
        t = min(t_ldd, t_pcie)
        rows.append((pg, t_ldd, t_pcie, t, h))
    for i,(pg,t_ldd,t_pcie,t,h) in enumerate(rows):
        jump = ""
        if i>0:
            prevt = rows[i-1][3]
            if prevt>0 and (t-prevt)/prevt > 0.15:   # 台阶 >15%
                jump = "  <-- 突变"
        print(f"  {pg:>5} {pg-TRUNK_GB:>5.0f} {h:>5.0f} {t_ldd:>7.1f} {t_pcie:>7.1f} {t:>6.1f}{jump}")
    # 找最大台阶
    best = max((rows[i][3]-rows[i-1][3], i) for i in range(1,len(rows)))
    print(f"  ── 最大台阶: +{best[0]:.1f} t/s @ 池 {rows[best[1]][0]}GB (命中 {rows[best[1]][4]:.0f}%)")
    # 两墙交叉点：PCIe限首次 ≥ LPDDR限 的池容量
    cross = next((pg for pg,t_ldd,t_pcie,t,h in rows if t_pcie >= t_ldd), None)
    if cross:
        print(f"  ── 两墙交叉: {cross:.0f}GB 之后 LPDDR 带宽成为瓶颈（PCIe补miss不再是墙）")

print(f"\n--- 旧口径（每颗独立128GB × ¥8/GB）---")
print(f"  内存: 224×128GB×¥8 = ¥{old_mem_total:>10,.0f} = {old_mem_total/1e4:.1f}万")
print(f"  整卡: 224×¥1,174  = ¥{old_total:>10,.0f} = {old_total/1e4:.1f}万")

print(f"\n--- 新口径（{POOL_GB:.0f}GB共享池 × ¥60/GB）---")
print(f"  芯片: 224×¥{DIE_COST}  = ¥{new_chip_cost:>10,.0f} = {new_chip_cost/1e4:.1f}万")
print(f"  内存: {POOL_GB:.0f}GB×¥{LPDDR_PRICE_NEW} = ¥{new_mem_cost:>10,.0f} = {new_mem_cost/1e4:.1f}万")
print(f"  PCB等:             = ¥{new_pcb:>10,}  = {new_pcb/1e4:.1f}万")
print(f"  整卡:              = ¥{new_total:>10,.0f} = {new_total/1e4:.1f}万")
print(f"  vs H200 ¥290万    = 1/{(290*1e4)/new_total:.0f}")

print(f"\n--- 内存成本对比 (内存总价 = 容量×¥60) ---")
print(f"  旧: 224×128×¥8  = ¥{old_mem_total:>10,.0f} = {old_mem_total/1e4:.1f}万")
print(f"  新: {POOL_GB:.0f}×¥60     = ¥{new_mem_cost:>10,.0f} = {new_mem_cost/1e4:.1f}万")
print(f"  净省: ¥{old_mem_total-new_mem_cost:>10,.0f} = {(old_mem_total-new_mem_cost)/1e4:.1f}万")
print(f"  原因: 单价×7.5 但总量缩 {old_mem_total/new_mem_cost:.0f}倍 → 内存反省 {(1-new_mem_cost/old_mem_total)*100:.0f}%")

# ===== 功耗/超频 (用户可调 --freq) =====
print(f"\n--- 功耗 / 超频 (--freq {args.freq or '默认匹配档'}) ---")
print(f"  DRAM 匹配档: MAC 最低频率 = {F_MATCH_GHZ*1000:.0f} MHz (P∝f³, 省电)")
print(f"  满档:        1.0 GHz (prefill/突发 = 100 档)")

freqs = args.freq if args.freq else [F_MATCH_GHZ, 0.5, 1.0]
print(f"  {'频率':>8} {'算力TMAC/s':>10} {'MAC功耗W':>9} {'总功耗W':>8} {'vs匹配':>7} {'速度影响':>10}")
for f in freqs:
    tmac = TOTAL_MAC * f / 1e3
    pw = calc_power(f)
    speedup = f / F_MATCH_GHZ
    need = TPS_K3 * K3_MAC_PER_TOKEN / 1e12
    if tmac >= need * 1.05:
        note = "DRAM瓶颈"
    elif tmac >= need * 0.95:
        note = "平衡≈匹配档"
    else:
        note = "MAC瓶颈←算力不足"
    print(f"  {f:>7.3f}GHz {tmac:>10.2f} {pw:>8,.0f}W {pw:>6,.0f}W {speedup:>6.2f}x {note:>10}")
print(f"  ↑ 匹配档仅是长期解码稳态频率；超频不提升稳态(K3受DRAM限), 但拉高prefill突发算力")

# ===== PCB 面积预算 v2 (N_MEM_DIES bank × 8die合封 + 1 LPDDR) =====
n_bk = int(round(N_MEM_DIES))
print(f"\n--- PCB 面积预算 v2 ({n_bk} bank × 8die合封 + 1 LPDDR) ---")
die_area = 5.6
bank_pkg = 8 * die_area * 1.6
lpddr_die = 100.0
bank_total = bank_pkg + lpddr_die
area_banks = n_bk * bank_total
extra = 2000 + 500 + 700 + 1200
CARD = 33384
tot = area_banks + extra
print(f"  每bank: 8die合封 {bank_pkg:.0f}mm² + LPDDR {lpddr_die:.0f}mm² = {bank_total:.0f}mm²")
print(f"  {n_bk} bank = {area_banks:,.0f}mm² + 走线/PCIe/电源 {extra}mm² = {tot:,.0f}mm²")
print(f"  卡 {CARD:,}mm² 占用 {tot/CARD*100:.1f}%  ✅")
print(f"  功耗: 匹配档 ≈{calc_power(F_MATCH_GHZ):,.0f}W / 满档 ≈{calc_power(1.0):,.0f}W (见上方超频档)")

print(f"\n{'='*70}")
print(f"结论: ¥{new_total/1e4:.1f}万 / {TPS_K3:.1f}t/s ≈ H200 / 1/{(290*1e4)/new_total:.0f} 成本")
print(f"{'='*70}")
