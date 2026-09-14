# FREQ600 — 保底决策在 termux 侧的物理边界(2026-09-14 终版)

## 一句话
**termux 中没有 PnR/时序引擎,任何"600 保底已具备"的 RTL 声称都不可验;termux 能
诚实产出的只有两件事 = ①124.3MHz 真硅证据的台账(已入库,PNR-EXPERIENCE 全文)与
②"600 需要 PC PLL-X800 哨兵 + fabric Fmax"的 PC 执行清单。**

## 已有真实硬证据(非哨兵,可复查)
| 项 | 数值 | 证据 |
|---|---|---|
| macsplit 引擎@200约束 PnR | Fmax=124.311MHz | PNR-EXPERIENCE.md §smoke（yosys synth rc=0 只是逻辑 rc，非时序）|
| 同上 引擎@无SDC PnR | unrouted=0 收敛时长证 | PNR-EXPERIENCE.md 全 PnR 品牌 |

## termux 物理做不到的
- PnR（place+route+时序收敛/上探）
- 800/600 的 fabric 真硅时钟树判定（PLL-X800 实体在 GW5AST 器件上物理成立是 PLL 数据手册域内事实，但 fabric 是否能收由 fabric Fmax 决定，termux 无法判）
- 所以「800/600 保底」不能在 termux 侧被证明，也不能在 termux 侧被否认 —— 只能 PC 真硅。

## PC 执行清单（烧录前最后一挡）
1. 立 `freq800_sentry_top` 哨兵（PLL→fabric 800MHz sentry 计数器→led lock/slow），综合+PNR，rc 观测 = lock 恒亮 + slow 翻转频率（详见 notes/FREQ800-FEASIBILITY.md §3）
2. 若 800 哨兵 PNR 不可收敛 → 记录 `route 单网 vs 800 周期` 实测差 → 800 全数据面物理不可行定案（已有 route 5.72ns 的 build sweep 日志佐证，可引用）
3. 若收敛 → 把 sentry 扩到最小 MAC 数据面(1 lane) 再判

## 台账纪律(termux 侧)
- 已删除：所有 800/600 哨兵 RTL 的**磁盘产物**（垃圾 D 状态已清理）
- 保留：sentinel 逻辑**源码**（systolic800_core_simple.v 等，供 PC 直接前生成哨兵）——作为"哨兵最小形态"RTL 参考，不声称已过 PnR
