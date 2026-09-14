# PC 烧录执行清单(唯一入口, README 顶部已链)
> termux 侧已把可复核的一切钉进台账; 本文件只写 **PC 真硅要做的动作**, 不新增声称。
> 2026-09-14 更新: 800/600 哨兵已完成真硅烧录, 本文件同时记录执行结果与勘误。

## 烧哪两块(按此顺序)
1. **macsplit 全数据面引擎**(真硅已实测 124.3MHz) — 若只是回归, 直接用仓库内已定案网表产物。
2. **800 哨兵**(本次要烧的目标, PLL-X800 + 全数据面 800MHz? 探路):
   - RTL: `rtl/13_mega138k/freq800_sentry_top.v`(800 域计数器 + lock 同步链, 纯 fabric)
   - 板级顶层: `rtl/13_mega138k/board_freq800_sentry.v`(PLL-X800 + key-LED 诊断复用版)
   - PLL 实体: **PLL-X800**(`rtl/13_mega138k/gowin_pll_x800.v`)
   - CST: `rtl/13_mega138k/freq800_sentry.cst`(sys_clk P16 50M / rst_n K16 / key F15 G15 G16 / led J14 M25 R26)
   - 构建: `rtl/13_mega138k/build_freq800_sentry.tcl`(route=2 place=3 max_fanout=100)
   - 产物: `out/138k_pro/freq800_sentry/board_freq800_sentry_r2p3/impl/pnr/board_freq800_sentry.bin`
3. **600 哨兵**(800 保底对照, 同结构不同 PLL):
   - `board_freq600_sentry.v` / `gowin_pll_x600.v`(50M→600M) / `freq600_sentry.{cst,sdc}` / `build_freq600_sentry.tcl`

## 观测点(判断哨兵是否成立)
LED 共阳低亮; key 按下=0, 逻辑已取反(1=亮)。LED 编号: J14=LED0 / R26=LED1 / M25=LED3。
key 组合 k={~key3,~key2,~key1}(按下=1), 视图(LED=[lock,slow,go]):

| k | 视图 | LED0 | LED3 | LED1 |
|----|-----|------|------|------|
| 000 | 基础 | pll_lock | cnt[5] | cnt[4] |
| 001 | 800低位 | cnt[3] | cnt[2] | cnt[1] |
| 010 | 800中位 | cnt[7] | cnt[6] | cnt[5] |
| 011 | 800高位 | cnt[27] | cnt[26] | cnt[25] |
| 100 | 心跳慢 | hb[25] | hb[24] | hb[23] |
| 101 | 同步链 | pll_lock | lb_dbg | la_dbg |
| 110 | 心跳快 | hb[17] | hb[16] | hb[15] |
| 111 | 锁测试 | pll_lock | pll_lock | pll_lock |

## 回退准则
- 视图111 三灯全灭 → PLL 不锁, 800 全数据面维持 600 保底(看 FREQ800-FEASIBILITY.md §backstop)。
- 视图000 LED0 亮但 LED1/3 不翻 → 计数器停摆, 调 `SLOWLOG` 再烧, 不扩大声称。
- 若时序未收敛但真硅在跑 → 以真硅为准记录, 同时留 PnR 报告供 PNR-EXPERIENCE。

## 执行结果(2026-09-14, PC 真硅)
```
PC-BURN-800:
  pll_lock: 恒亮(视图111 三灯全亮) => PLL-X800 锁住 PASS
  led_slow: LED1/3(counter) 微亮翻转 => 800MHz 域计数器在跑
  结论: PLL 锁 PASS; clk_800 域 wpst 路径 SETUP -1.177ns(工具未收敛),
        真硅已跑 => 800 PLL 可行, 全数据面 800 维持 600 保底
  PnR 日志: out/138k_pro/freq800_sentry/*/impl/pnr/
PC-BURN-600:
  pll_lock: 视图111 三灯全亮 => PLL-X600 锁住 PASS
  结论: 600 哨兵对照 PASS; clk_600 域 SETUP -0.760ns
```

## 勘误(2026-09-14)
- **FBDIF 配置 bug**: gowin_pll_x800.v 原 FBDIF_SEL=16(+MDIV=16) → VCO=12800MHz
  超范围(650-1300), PLL 物理不锁, 首次 SENTRY-FAIL 为假象。修正 FBDIF_SEL=1
  (VCO=50*1*16=800MHz) 后锁上, PA1019/TA1123 告警消失。
- **led_lock 引脚**: 原定 L25 经查为自由 GPIO 非板载 LED, 实际接 J14(LED0)。