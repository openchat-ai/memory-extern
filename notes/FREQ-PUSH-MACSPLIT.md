# FREQ-PUSH-MACSPLIT — 引擎频率上探方案(PC 接续)

状态: 已立档未执行(2026-09-14, termux 侧仅能做方案定格)
目标: macsplit 引擎从实测 124.3MHz 向 200MHz 目标上探, 每档收敛必须**实物烟熏验真**, 杜绝坏网表虚值。

## 实测基准(勿被旧数字混淆)
- full_macsplit    : 97.6MHz(引擎, 未达 200)
- macsplit_reg     : 129.4MHz = **废物**(Gowin 综合器双实例等价寄存器合并 bug 的坏网表, 勿引用)
- macsplit_dontouch: 91.4MHz(修 bug 后真值)
- macsplit_smoke   : **124.3MHz** 真硅实测 / TNS -4559.665 / 5631 端点 / Hold 全满
  回归命令: route=2 / place=3 / max_fanout=100 + CST; PLL 400 design 从未上板。

## 瓶颈定性(证据链在 PNR-EXPERIENCE.md §8)
- 最差路径 cell ~14~21% / **route ~74~82%** → 布线主导, 非逻辑深度
- 路径族① `x_q → kx_pipe`(x 输入全局扇出后跨实例布线)
- 路径族② `prod_pipe0 → acc`(32bit 进位链 + u_mac_lo → u_mac_hi 跨实例长网, 单段 tNET 5.525ns)
- 128-lane 单实例全局网 = PnR 死循环根因; macsplit(2×64 独立)已治本
- 时钟资源: 目标器件时钟容量内, 建议加 `CLOCK_LOC "net" LOCAL_CLOCK` 物理时钟约束

## PC 执行序(每步验 .vg + 实物 smoke)
1. **布局规整化(首选)**: CST/pblock 把 u_mac_lo/u_mac_hi 两实例分离且各自就近
   - 前提: 修网表后再 PNR(当前 smoke 网表已含 dont_touch 修复, 已验证 hi 实例 prod_pipe0=0)
   - 作用: 定向杀跨实例长网(路径族② 单段 5.5ns)
2. **降扇出复制**: `-replicate_resources 1` + kx 广播网 `/* synthesis syn_maxfan = 8~10 */`
   - 作用: 杀路径族① 全局扇出长线
3. **累加链再流水 / DSP 乘**: 仅在布局/扇出用尽后引入(改变数据面, 需同步更新 LOCKSTEP 对账)
4. **增量收敛**: 出现 seed 后 `-inc_place auto -inc_pnr auto`, 单次 PNR 压到 <5min

## 验收
- `.vg` 逐字核对: hi 实例内部自足(prod_pipe0/kx_pipe 无共享、lane 索引不错位)
- 实物 smoke: 原字段跑通 + LED 判活; Fmax 实收 ≥ 150MHz 即认为方案成立(单档)
- 波形/计数: sync clock domain report Hold 全满、Setup TNS 每档递减

## 回退准则
- 任一档发现跨实例逻辑共享/lane 错位 → **停** 并回报(判定坏网表, 该档不计)
- 计时预算: 单档 PNR ≤30min, route_option=2 起步