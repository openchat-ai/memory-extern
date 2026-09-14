# PC 烧录执行清单(唯一入口, README 顶部已链)
> termux 侧已把可复核的一切钉进台账; 本文件只写 **PC 真硅要做的动作**, 不新增声称。

## 烧哪两块(按此顺序)
1. **macsplit 全数据面引擎**(真硅已实测 124.3MHz) — 若只是回归, 直接用仓库内已定案网表产物。
2. **800 哨兵**(本次要烧的目标):
   - RTL: `rtl/13_mega138k/freq800_sentry_top.v`(800 域计数器 + lock 同步链, 纯 fabric)
   - PLL 实体: **PLL-X800**(PC 器件内置; termux 无实体, 故 termux 不掷 800 可行性)
   - CST: `cst/mega138k_engine.cst`(sys_clk P16 50M / rst_n K16 / led L25 M25 R26) — 哨兵仅动 led, 其它引脚映射同引擎。

## 观测点(判断哨兵是否成立)
| 信号 | 引脚 | 真硅成功 = |
|------|------|-----------|
| led_lock (PLL lock → 50 域) | L25 | 恒亮 |
| led_slow (800 域计数高位) | M25 | 周期翻转(termux tb 行为域已 PASS: 48 次翻转 / 3000 拍) |
| led_go (lock 后哨兵运行) | R26 | 恒亮 |

## 回退准则
- led_lock 不亮 或 led_slow 不翻 → 800 PLL-X800 物理哨兵 `FAIL`, 800 全数据面维持 600 保底(看 FREQ800-FEASIBILITY.md §backstop)。
- 若锁亮但 slow 翻转混乱 → fabripc 计数器分频比微调 `SLOWLOG` 再烧, 不扩大声称。

## 执行后回报格式(塞回 termux 台账)
```
PC-BURN-800:
  pll_lock: (恒亮/闪烁/灭)
  led_slow: (翻转Hz可测值 or 不翻)
  结论: SENTRY-PASS / SENTRY-FAIL
  PnR 日志: (路径, 无 PnR 引擎的 termux 不接受声称, 附上才可入 PNR-EXPERIENCE)
```
