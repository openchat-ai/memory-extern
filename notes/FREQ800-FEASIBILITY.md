>>> 2026-09-14 勘误(termux 侧记账错误已修): 先前声称的"800哨兵RTL已交付/综合rc=0"
>>> 不实 —— termux 无 PnR 引擎, 纯 yosys 语法通过不构成"800 可行"证据; 该类哨兵
>>> RTL 与产物已从追踪与磁盘删除。唯一真实上硅证据 = macsplit 引擎@124.3MHz
>>> (PC 真硅实测, 全套 PnR 日志在 PNR-EXPERIENCE)。800/600 需 PC 真硅(PLL-X800
>>> 实体 + fabric Fmax)才能判, termux 侧不予陈述。

# FREQ800 可行性:真硅判定 (PC 2026-09-14, key-LED 诊断版)

## 上硅实测证据 (Tang Mega 138K Pro, GW5AST-138B)

### 工程1: freq800_sentry (PLL-X800 实体, 计数哨兵)
- PLL 配置修正经过: 首发 gowin_pll_x800.v FBDIV_SEL=16(+MDIV=16) → VCO=50×16×16=
  12800MHz 远超范围(650-1300), PLL 必不锁 → 修正 FBDIV_SEL=1 (VCO=800MHz, clkout=800)。
  修正后 PnR 无 PA1019(频率不匹配)/TA1123(VCO 超范围)。
- 烧录观测 (key-LED 视图 000 默认三键松开):
  - LED0(pll_lock): **常亮** ≈ PLL 锁定
  - LED1(cnt[4]=50MHz), LED3(cnt[5]=25MHz): **半亮**(50% 占空翻转) ≈ 800MHz 计数在跑
  - 视图111(三键齐按=pll_lock×3): 0/1/3 **全常亮** → pll_lock 恒 1 **实锤**
  - 视图100/110(clk_50 心跳): 低频微闪/高频半亮 → 50MHz 域与 LED 驱动链健康
- 结论: **PLL-X800 锁定 PASS**; 但 fabric 最差 SETUP slack = -1.177ns@clk_800(trim)
  → **计数链 1.25ns 不收敛**。即 800MHz 时钟硅上真实存在且能跑计数器, 但全数据面
  800MHz 时序不闭合, 决策仍维持 600 保底。

### 工程2: freq600_sentry (PLL-X600, 计数哨兵)
- 配置: FBDIV=1, MDIV=24, ODIV0=2 → VCO=1200MHz → clkout=600MHz
- 烧录观测: 视图111 0/1/3 常亮 = PLL 锁定 PASS; fabric 最差 SETUP slack = -0.760ns
  @clk_600(trim) → 优于 800 但同样不闭合(28bit 计数链深度所致, 哨兵用 800 域直连
  计数链, 非最优 50MHz 域路径)。

## 定论
- 800MHz PLL: PASS(实体真锁, 非硅不可行)
- 800MHz fabric 全数据面: FAIL(时序不封闭, -1.177ns) → **600 保底决策维持**
- 错误澄清: 首发 SENTRY-FAIL 是 PLL 静态配置 bug(非硅失败), 已修正并真硅复验