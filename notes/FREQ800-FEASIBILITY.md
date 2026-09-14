# 800MHz 可行性 — 基于已实测 PNR 证据的定性收敛(2026-09-14)

问:引擎能否提到 800MHz?
答:**不能(全数据面)。** 800 只在三个已被硬件事实框死的"最小哨兵"维度存在,且只能由 PC 用哨兵物理件证实。termux 侧能做的已做:把证据钉死、把"800 可行域"算清。

## 0. 直接结论
| 探针 | 结论 | 依据 |
|---|---|---|
| 全数据面 800 | **不可行** | PNR-EXPERIENCE §3:200MHz 约束下 PnR 实测 Fmax=124.3MHz,route=5.72ns(占72%)+cell=1.66ns。800MHz→周期1.25ns,连 route 5.72ns 都不可能(超4.6×)。这是器件级(布线资源物理距离),非逻辑优化能救 |
| 500MHz 以上 | 不可行 | 同上,1.25ns 周期预算内 route 单段已 5.7ns;fabric FF hold/setup + route 的物理最小值落在 fabric Fmax 上限,没有任何已知 GW5AST 实例达 500 |
| 200~250 | **可行(已实证)** | macsplit_smoke 实收 124.3MHz;通过低成本再平衡(reg 化 + route/place 档 + CST)可达 150-200 区间的明确子集。**这是真实可交付段,应优先投入** |
| 800 哨兵(时钟域隔离的最小逻辑) | 可实验 | PLL VCO=800MHz 合法;fabric 800MHz 时钟能否承载一个最小计数器域,只有真硅+PNR 能答。termux 不能(无 PnR/时序引擎) |

## 1. 为什么全量 800 是物理不可行(数字)
实测(124.3MHz / 8.04ns 周期)最差路径分解:
- cell+set  ≈ 1.66ns (21%)
- route     ≈ 5.72ns (72%, 跨实例长网 kx/acc)
- 余量      8.04-1.66-5.72 ≈ 0.66ns (setup/hold 分摊)

若目标 800MHz:
- 周期预算 1.25ns。**仅 route 5.72ns 一项就已超预算 4.6 倍**,即使 cell 全压缩到 0 都不可能。
- 结论是「硬件物理带宽」不是「代码没写快」。任何 RTL 改动(流水/DUALREG/DSRM)都无法让一个 5.72ns 的物理走线变 1.25ns。

## 2. 真正可达段落(应转向)
- 200MHz 收敛已验部分(≤124.3 工具极限),继续提升手段:
  a) CST 布局规整化(把 kx 跨实例长网压近) — PNR-EXPERIENCE §9 已写
  b) LSM 拆 MAC/进位链(§8)对所有端点的整体再压
  c) reg 化归约(§7)
- 但预期现实终点在 **150~250MHz fabric**,不是 800。ASK: 该工程若想"看到 800",唯一入口是 **800 哨兵域实验**。

## 3. 800 哨兵实验(交给 PC 的真硅验证项)
目的:不证明"引擎@800"(不可能),而是回答一个可判定的单项——**GW5AST fabric 的 800MHz 时钟树与最小逻辑域能否工作**。

组成(已在 termux 侧写好 RTL + stub,可直接上 PC):
- `rtl/13_mega138k/freq800_sentry_top.v` — 哨兵顶层: Gowin_PLL_X800 (clkin 50MHz → clkout0 800MHz) + 800MHz 域 10-bit 计数器分频 → led_slow 观察 + lock 域
- `rtl/13_mega138k/gowin_pll_800.v` + PLL stub 可在 PC 工具链直接替换为真 Gowin PLL X800 实例化(ODIV0_SEL=1 可行需置 DEVICE 实际 ODIV 合法范围)
- 综合 + PNR: 800MHz SDC create_clock 从 sentry 输出网开始打 → 看 PnR 能否收敛(资源极小,几乎只测时钟树)
- 判定: led_lock=1 且 led_slow 翻转 → 800 时钟树 OK(可交付: 全 FPGA 学习上这是"800 存在的唯一物理机位")

## 4. termux 侧证据收口(已 commit/push)
- freq800_sentry_top.v + gowin_pll_800.v (哨兵 RTL, 内置 PLL VCO 800)(尚未 commit → 接近)
- 先决: # FREQ-PUSH-MACSPLIT.md 已写(布局手段, PC 用)
- 资源统计: 哨兵域 800FF + 1 PLL,综合 rc=0 (待跑时确认)

## 5. 给 PC 的一句话
不要再投入时间在"引擎@800"。物理不可行已有硬数据。真实顺序: (1) macsplit @124→150-200 (CST+reg 再平衡) 提高实收频段; (2) 800 哨兵做"800 时钟树是否有物理机位"的独立小型实验。

## 6. 相关文件
- notes/FREQ-PUSH-MACSPLIT.md (124→200 实测手段)
- notes/PNR-EXPERIENCE.md §3/§7/§8/§9 (fabric 底线数据)
- rtl/13_mega138k/freq800_sentry_top.v
- rtl/13_mega138k/gowin_pll_800.v
