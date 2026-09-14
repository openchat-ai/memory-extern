# UPWORK-ENTRY — 国外平台 FPGA 接单入场包(2026, 账实一致)
> 状态: 待你按表打钩 · 市场证据已拉齐(Payoneer/Wise/Upwork/Freelancer 费率带) — 见本轮检索
> 纪律: 本表只是"能上线的清单", 不是"能接单"的结论。上完线、过完认证, 才是第一步。

## 0 三条硬账(先认清, 别做梦)
1. 平台抽成: Upwork 前$500收20%→$500-10000收10%, >$10000收5%; Fiverr抽20%; 众包些更高
2. 收款: Upwork/Fiverr → Payoneer(1.2%提现+2%汇率加价) 是默认; Wise 不能直接接 Upwork; 直接客户走 Wise(0.4-1%)更省
3. 税务: 中国税收居民境外所得必须申报(劳筹20-40%累进), 获批可抵免(境外已缴税), Upwork 填 W-8BEN 可免30%预扣

## 1 平台选型(按你的射程)
| 平台 | 门槛 | FPGA 单量 | 报价带 | 抽成 | 结论 |
| --- | --- | --- | --- | --- | --- |
| Upwork | 低(个人实名) | 大, FPGA 是热类 | $40-80/时中缝 | 5-20% | **首选**, 第一站 |
| Freelancer.com | 低 | 中 | $33-80/时 | 高 | 备选(报价更卷) |
| Toptal | 高(面试<3%过) | 大 | $100-150/时 | 申请制 | 过了才值, 先别想 |

## 2 作品集: 把真硅台账翻译成平台语言(最难也最值钱的一步)
> 规则: 平台认"可回查的验证证据", 不认"我说我行"。你正好有别人伪造不了的真硅证据。

### 封面title(英文, 一句话)
`FPGA Design Engineer | Timing Closure & Silicon-Proven Verification | Gowin/123.9MHz True-Silicon`
(避免"Senior/Expert"这类要资质的词, 用"Silicon-Proven"这种可验证的)

### 3-5 个案例卡(每个 800 字符内, 英文)
格式固定五段:
1. **Problem/背景**: 甲方要什么(1句)
2. **What I did**: RTL/接口/PLL/时序(3-4条)
3. **Evidence(不能撒谎的关键段)**: 真硅观测/LED/slack数据(账实一致! 这是你的招牌)
4. **Result**: 时序收敛 / 60真锁 / 上板观测
5. **Tools**: Tang Mega 138K / GW5AST-138B / GOWIN PnR / analog Sta / 板级

### 证据素材(都已在库, 直接调)
- `rtl/13_mega138k/*_sentry_result.txt` → 真硅PLL锁存观测
- `notes/FEASIBILITY.md / FREQ800-FEASIBILIY.md` → STA slack 数字
- 板级: Tang Mega 138K 138B
> 注意: 客户只要"报告/罐头权限", 别发全部源码; 合同盾顶住(CONTRACT-SHIELD.md)

## 3 注册+认证 checkBox(照表打钩)
- [ ] Upwork 账户(实名+邮箱+学生证), 填完 profile 100%
- [ ] 技能测试不必要, 但加"作品集链接"到 profile
- [ ] Payoneer 账户(中国护照,1-3工作日), 绑定 Upwork
- [ ] W-8BEN 表(填 China → 免30%预扣) ← 最容易被漏, 坑
- [ ] Wise 个人(直接客户收款, 0.4-1%), 先不开 Wise Business(要公司)
- [ ] 报价: 中缝 $40-60/时 起步(别一上来$100, Upwork 要积累)

## 4 订单节奏(头30天)
- W1: 上线+完善profile, 发 10 个 proposal(每个个性化, 别模板)
- W2-4: 专挑"时序收敛/验证/GA外围"标签, 报价 $40-60; 目标是拿到一个 5 星评价
- 里程碑验收 → 用 CONTRACT-SHIELD.md 兜底, 别裸奔

## 5 一句话
平台替你找了绳子, 作品集是你的证据, 合同盾是你的手套。上线开闸, 第一单来了我叫你。板继续烧, 账两头都进——真硅台账 + 接单台账, 一样都不亏。
