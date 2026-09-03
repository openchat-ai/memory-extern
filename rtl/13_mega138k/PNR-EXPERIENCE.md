# Tang Mega 138K Pro �?PNR 实战经验与工具参数速查

> 器件：GW5AST-LV138FPG676AES�?38K Pro，Meteor/晨熙 家族�?> `set_device` 须带 `-device_version B`；`gw_sh.exe`：`D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe`
> 权威参数语义来源：`SUG1220-2.0_Gowin云源软件Tcl命令用户指南.pdf`；时序收敛指导：`SUG113-1.3_Gowin器件设计优化与分析用户指�?pdf`（均位于 `D:\Gowin\...\IDE\doc\CN\`，可�?PyMuPDF/fitz 直接提取文本）�?
## 1. PNR 工具选项权威语义（SUG1220�?
| 选项 | 取�?| 默认 | 语义 / 备注 |
|---|---|---|---|
| `-route_maxfan` | **1~100**（整数） | 23 | 绕线最大扇出数目。小器件（GW1NZ-1/GW1N-2 等）默认 10�?*上限 100，不能设 128/256**�?|
| `-place_option` | 0~4 | 0 | 布局算法选项�? 默认 / 1~4 四种算法�?|
| `-route_option` | 0~2 | 0 | 布线算法选项�? 默认 / 1~2 两种算法�?|
| `-timing_driven` | 0/1 | 1 | 是否时序驱动布局布线�?*关闭的正确选项名是 `-timing_driven 0`** |
| `-global_freq` | default/数�?| �?| 目标全局频率约束 |
| `-clock_route_order` | 0/1 | 0 | 非时钟原语时钟线的绕线分配顺序：0=按扇出降序；1=按频率降�?|
| `-correct_hold` | 0/1 | 1 | 布线�?hold 违规自动修复 |
| `-replicate_resources` | 0/1 | 0 | 对高扇出资源复制降扇出、改善时序�?*注意：会增加 net 数量，与拥塞方向相反，拥塞场景慎�?* |
| **`-inc_place`** | 0/auto/file | 0 | **增量布局**：auto=自动；file=指定 *.p。复用上次布局结果�?|
| **`-inc_pnr`** | 0/auto/file | 0 | **增量布局布线**：auto=自动；file=指定 *.p/.db�?*快速迭代核心：拿到一个收�?seed 后用它把每次 PNR 压缩到几分钟�?* |
| `-enable_dsrm` | �?| �?| SUG1220 未收录，语义未知（并发工作流 cmd.do �?0�?|
| `-ireg/oreg/ioreg_not_in_iob` | �?| �?| 不把 IO 寄存器放�?IOB（并�?cmd.do 在用；默认是 `*_in_iob 1`�?|
| `-cst_error` | �?| �?| 物理约束警告提升为错误（SUG1220 中为 `-cst_warn_to_error`，默�?1�?|
| `-convert_sdp32_36_to_sdp16_18` | 0/1 | 0 | 32/36 位宽 SDP �?2 �?16/18 位宽（仅 Arora V 支持�?|

### 增量布局布线的用法（最重要�?```tcl
set_option -inc_place auto   # 或指�?seed 文件：set_option -inc_place <xxx.p>
set_option -inc_pnr   auto   # 或指�?seed：set_option -inc_pnr <xxx.p>
```
默认都是 0（关闭）。目�?5 分钟完成布线 + 200MHz"的核心手段：
1. 先用较宽松参数跑出一个能收敛�?seed�?p/.db）；
2. 之后所有参数调整都�?`-inc_pnr auto` 增量迭代，单�?PNR 大幅缩短�?
## 2. SUG113 时序收敛要点

- **逻辑级数**：晨熙（Meteor）家�?C8 速度档，100MHz 建议 �? 级逻辑�?*200MHz 目标约需 �? �?*�?- **资源过用阈�?*：CLS 占用 �?5%，或 BSRAM/DSP �?0%，即"过度利用"，会导致时序收敛问题。本设计资源仅用 ~9~12%�?*排除资源过用因素**�?- **高扇�?net**：最差路径若 net delay 大且 fanout 大，�?RTL 综合属�?`/* synthesis syn_maxfan = N */`（如 `syn_maxfan = 10`），或用工具 `-replicate_resources 1` 复制资源降扇出�?- **跨模�?net**：net delay 大但 fanout 不大时，检查是否跨多个模块，降低跨模块次数�?- **时钟资源**：时钟数不应超出目标器件时钟总量，否则部分时钟线会绕普通绕线资源引�?setup/hold 违规。可加物理约�?`CLOCK_LOC "net" LOCAL_CLOCK;`�?- **存储/乘法�?*：最差路径由 BSRAM/DSP 引起时，在其最终输出再打一拍�?
## 3. 实验记录�?28-lane + LCD 完整�?vs 对照�?
| 实验 | 配置 | 结果 | 耗时 | unrouted |
|---|---|---|---|---|
| build8 | place=3 / route=2 / �?SDC | 失败 | 5h44m | 700 |
| build9 | place=0 / route=0 / �?SDC | 失败 | 46min | 2701 |
| build10 | place=3 / route=0 / �?SDC | 失败 | 38min | 2333 |
| **probe** | 64-lane / �?LCD / 单时钟域 200MHz PLL | **成功** | Total 4m56s（Routing Phase 1 4m22s，Placement 9s�?| 0 |
| sweep_200m | 完整�?128-lane+LCD) / 200MHz / async SDC | **DIED_EARLY**（exit=-1�?| Phase 1 �?14min 被并发守�?TerminateProcess | �?|
| **eng200** r0p0 | 128-lane / �?LCD / 单时钟域 200MHz PLL | **DIED_EARLY**（无标记消失�?1:36 前） | Routing Phase 1，无产物 | �?|
| **eng200** r2p0 | 同上，route_option=2 | **DIED_EARLY**（树级硬杀 11:58:26�?| Phase 1 全程健康满载（CPU 30s/30s）后被进程树 TerminateProcess；launch 父进程同殒、exit.txt 未生�?| �?|
| **probe128_g64** | 128-lane / GROUP_LANES=64 / �?LCD | 一�?FAIL(5.4s) + 二轮 DIED_EARLY(~12:03) | 一�?sdc 违例快死；二�?Routing Phase 1 父进程同消失 | �?|
| **probe_dsplit** | 128-lane / 数据通路拆两�?64 收敛�?| **DEADLOOP**�?202.9s �?rpt�?| 12:41:13 被用�?runner �?DeadlockAfter 强杀；归约顶已最小仍 Phase 1 无产�?| �?|
| **macsplit** | 128-lane / MAC 阵列拆两个独�?64-lane 实例 + 各自归约 | **成功** | Total 9m53s（Phase 1 �?5min 收敛，同 probe64 量级�?| **0** |
| **full_macsplit** | **完整板（128-lane + LCD + 双时钟域 + SDC 200MHz�?* / macsplit 结构 | **成功** | Total 26m43s（Phase 1 �?8min，Phase 2 �?12min）；**引擎 Fmax=97.6MHz 未达 200MHz** | **0** |
| **macsplit_reg** | full_macsplit + **归约�?stage �?FF �?*（generate 显式寄存器版�?| **成功** | Total 338s�?*引擎 Fmax=129.4MHz�?7.6�?29.4�?33%），TNS -20859�?11655**；Hold 全满�?| **0** |

- probe 报告：`out\138k_pro\probe\board_top_probe\impl\pnr\board_top_probe.rpt.txt`（峰值内�?1700MB）�?- build10 报告：`out\138k_pro\synth\board_top\impl\pnr\board_top.rpt.txt`（峰值内�?2177MB）�?
### Phase 明细对比（rpt.txt "Total Time and Memory Usage"�?
| 阶段 | probe（成功，64-lane�?| build10（失败，128-lane+LCD�?|
|---|---|---|
| Placement | 9s | 1m13s（P0 1s / P1 0.4s / P2 24s / P3 48s�?|
| Routing Phase 0 | 1s | 1s |
| Routing Phase 1 | 4m22s | 37m55s |
| Routing Phase 2 | 0.427s | 0.001s（有残留�?放弃"只跑 1ms�?|
| Routing Phase 3 | 0s | 0s |
| Total Routing | 4m24s | 37m56s |
| Total | 4m56s | 39m10s |
| 峰值内�?| 1700MB | 2177MB |

- **失败模式**：build8/9/10 �?*走完 4 �?Routing Phase�?0%�?0% 标记齐全）后才报 ERROR(PR0004)** �?不是中途死锁，�?管线跑完、Phase 2 收尾救不�?。几乎全部时间耗在 Phase 1（DesRoute）�?- sweep_200m：卡 `[60%]` 14 分钟（CPU 172.8s�?51.8s，单�?100%，log 零更新属正常态）后被杀�?*未跑完、无 rpt**�?
## 4. 关键结论（血泪教训）

1. **三次失败时参数全是默认�?*（`route_maxfan 23`=默认、`place/route_option 0`=默认）→ 不是"参数写错"，而是**默认策略在此设计规模/时钟结构下无法收�?*�?2. **SDC 不是布线失败主因**：build8/9/10 均无 SDC 仍失败�?3. **"死循�?真相**：Routing Phase 1 超长布线（build8 �?5h44m），不是死循环，�?DesRoute 无法收敛�?*失败=完整跑完 4 �?Phase �?Phase 2 收尾救不回，几乎全部时间耗在 Phase 1**�?4. **probe 成功基线**�?4-lane、无 LCD、单 PLL 200MHz 时钟�?�?引擎自身（含 200MHz）能 5 分钟布通。怀疑对象收窄为 **128-lane 规模**（net 拥塞爆炸）与 **LCD + 多时钟域跨域路径** 二选一或叠加�?5. **改工具参数后必须验证确实生效**：看新跑 log 的报�?输出行是否真的变了（全局调试纪律）�?6. **route_option 是收敛质量杠杆（实证�?*：build8（route=2）unrouted=700 明显优于 build9/10（route=0）的 2701/2333，代价是耗时 5h44m。→ 收敛质量可�?route_option 显著改善�?7. **并发守卫会强杀长跑**：sweep_200m �?CPU�?60s（约 16 分钟 Phase 1）时被并发流�?`exit=-1`（TerminateProcess）终止，无任何结果产�?�?长跑 PNR 必须由自己的守卫接管，不能让第三方按 CPU 阈值杀掉�?8. **128-lane 难布的根本机�?= simd_mac_array 128-lane 本体的全局扇出/广播网超布线�?Phase 1 收敛能力，不是资源、不是归�?merge**�?   - **资源反证**：build10 REG=7952/139140=6%、LUT/ALU=11930�?.6%�?4% 逻辑空闲却放�?2333 net �?拓扑拥塞而非容量问题�?   - **排除�?*：probe64 收敛（Phase 1 4m22s）→ probe128_g64（GROUP_LANES=64 仅改顶层分组）死 �?**probe_dsplit（数据通路级拆成两个与 probe64 完全同构的独�?64 收敛块、顶层仅 2 输入相加）仍 DEADLOOP** �?**macsplit（MAC 阵列也拆成两个独�?simd_mac_array(64) + 各自归约）成功（unrouted=0，Total 9m53s�?* �?归约 merge 不是瓶颈�?*simd_mac_array 128-lane 单实例的全局网才是死循环根源**：`x_data` 1024bit + `wt_data` 512bit 广播�?128 lane（PIPE_IN=1 已打断仍 128 扇出）、`acc_bus` 4096bit 全局扇出到归约入口�?*结论：把阵列实例化边界拆小（2×64 独立 simd_mac_array）即修复�?*
   - **1�? 超线�?*�?4�?28 �?acc_bus 翻倍（2048�?096bit），Phase 1 �?4m22s 飙到 >20min 仍无 rpt；macsplit 证明�?**64-lane 收敛�?*划分实例化边界（每个 <5min 收敛）即治本，无需�?lane 位宽�?   - **完整板确认（full_macsplit�?*：macsplit 结构 + 完整 LCD/双时钟域/SDC 也收敛（Total 26m43s、unrouted=0、bitstream 生成），证明「阵列实例化边界拆分」在完整板（�?LCD 全局布线 + 3 时钟）下依然有效�?*不是靠砍 LCD 才收�?*�?   - **代价（新瓶颈�?*：拆分后引擎 Fmax=**97.6MHz**（Logic Level 5，Data Delay 10.19ns vs 200MHz 周期 5ns），关键路径 = MAC `acc_*` �?归约�?`stage0` 加法器（32bit 进位�?+ acc_bus 2048bit 布线），TNS=-20859�?0375 端点）。LCD 35MHz 满足（Fmax 140.7MHz），HOLD 全满足�?   - **归约�?stage RAM→FF 化有效（macsplit_reg�?33%�?*：stage 归约不再是最差路径。Fmax 97.6�?29.4MHz、TNS -20859�?11655、Logic Level 5�?�?*新瓶�?= 布线主导**（最差路�?cell 1.658ns/21% + route 5.720ns/74%）：
     - 路径族① `x_q`（输入流水寄存器）→ `kx_pipe`（乘�?MUX 进位链）——x 输入全局扇出后跨实例布线�?     - 路径族② `prod_pipe0` �?`acc`（累�?32bit 进位链）——且出现 **u_mac_lo �?prod 驱动 u_mac_hi �?acc** 跨实例长网（单段 tNET 5.525ns，R68C39→R56C114）。两实例�?RTL 完全独立，此路径疑似综合器跨实例逻辑共享/折叠或布局把两实例 lane 混放所�?�?**布局规整化（物理约束把两实例分离/就近）是下一个干预点**�?9. **并发 runner 会无差别清场近期启动�?gw_sh**：`tools\build_with_deadline.ps1` �?~96-100 �?DEADLOOP/TIMEOUT 清理�?kill 所�?`StartTime �?本次build start-2s` �?gw_sh�?*只杀 gw_sh，不杀 powershell 父进�?*）�?28-lane 长跑连续被「进程树级」硬杀（sweep exit=-1、eng200 r0p0/r2p0、probe128_g64×2，launch 父进程同步消失、exit.txt 未写）→ 杀手非崩溃/WER/计划任务/内存�?*仍未定位**；结�?= 长跑 PNR 实验须与并发工作流错峰、由自身守卫接管，并�?watch 里加「消失前 5 分钟新启动进程」追踪定位清场者�?
## 5. PNR 状态判读：只信真实信号，不�?log 猜测

**死规则：`log 长时间不动` 永远不是"卡死"判据**——Routing Phase 1 期间 log 本来就不写（sweep_200m 实证 14 分钟零更新属正常）。log 只当"一次性事件源"（出�?`[70%]`/`ERROR (PR0004)`/`Generate *.rpt` 才有意义）�?
可观测真实信号（按优先级）：

| 信号 | 采样方式 | 判断作用 |
|---|---|---|
| 进程存在�?| `Get-Process -Id <pid>` | 消失=结束；无产物=被杀/崩溃（DIED_EARLY�?|
| **CPU 时间增量** | 间隔 `Δt` �?`CPU` 增量≈`Δt` | **Phase 1 期间唯一可靠�?活着且在�?心跳** |
| WorkingSet 曲线 | `WorkingSet64` | 应单调爬�?~2.2GB 峰值；停滞≠卡死，CPU 停滞才算 |
| **产物文件** | `.rpt.txt`/`.fs`/`.bit` 出现 | **终结判据**：rpt 出→grep `PR0004 N` 判成�?数量；fs �?整套成功 |

判定脚本：`watch_pnr.ps1`（见下）采样�?状态机，一次性采样（`-Once`）或后台循环（`-Loop`）。状态：`ACTIVE` / `LOW_ACTIVITY`（连�?N 次后）→ `STUCK` / `FAIL_ROUTE(N)` / `PNR_DONE` / `BITSTREAM_DONE` / `DIED_EARLY`�?
```powershell
# 一次性检查（主会话用，不驻留�?powershell -File watch_pnr.ps1 -Pid <gw_sh_pid> -ResultDir <impl\pnr> -EventLog <run.log> -Once
# 后台循环（Start-Process 独立启动，落盘）
powershell -File watch_pnr.ps1 -Pid <gw_sh_pid> -ResultDir <impl\pnr> -EventLog <run.log> -Loop -Interval 30
```

## 6. 后续策略索引（待执行�?
1. ~~采集并发 sweep_200m 结果~~ �?**已死**（exit=-1，被守卫强杀），不计为对照�?2. ~~二分定位 eng200�?28-lane + 200MHz 单时钟域、无 LCD）~~ �?**r0p0/r2p0 �?DIED_EARLY（杀手未定位），未及布通判�?*；重跑需避开并发窗口 + watch 加杀手侧写�?3. ~~probe128_g64 / probe_dsplit~~ �?**均死（DEADLOOP/DIED_EARLY�?*；「归�?merge」已排除，主因锁�?**simd_mac_array 128-lane 本体全局�?*�?4. ~~�?MAC 阵列全局网实验：128-lane 拆成 2 个独�?simd_mac_array(64) 实例 + 各自归约~~ �?**macsplit 已成功（unrouted=0，Total 9m53s�?*�?*治本方案确定：按 64-lane 收敛块划分阵列实例化边界**�?   - �?**完整板集成已验证**：full_macsplit�?28-lane + LCD + SDC）布�?unrouted=0，bitstream 生成�?   - �?**归约�?stage RAM→FF 化已验证**：macsplit_reg（generate 显式寄存器版）Fmax 97.6�?29.4MHz�?33%）、TNS -20859�?11655�?*stage 归约不再是瓶�?*�?   - �?**下一目标：引�?200MHz 时序**�?*注意：当�?macsplit_reg 的时序结果建在损坏网表上（见 §8 合成器缺陷），须先修复双实例寄存器等价合并，才能得到真实时序基准�?* 修复后的方向仍为：① 布局规整化（CST ）；�?累加进位链再流水 / DSP 乘法；③ replicate_resources�?5. 工具参数梯度（以 probe 成功配置为基线）：优�?**`route_option 2`（实�?2333�?00�?* �?`route_maxfan 23�?0�?00` �?`place_option 1/2` �?`clock_route_order 1`�?6. 出现收敛 seed 后：`-inc_place auto -inc_pnr auto` 增量迭代，把单次 PNR 压到 5 分钟内�?7. 布通后�?200MHz 时序：按 SUG113 减逻辑级数（≤4 级）或对关键高扇�?net �?`syn_maxfan` / �?`-replicate_resources 1`�?
## 7. 已定位文件速查

- probe 顶层：`rtl\13_mega138k\board_top_probe.v`（NUM_LANES=64，无 LCD�?- **eng200 二分顶层：`rtl\13_mega138k\board_top_eng200.v`（NUM_LANES=128，无 LCD，单 200MHz 时钟域）**
- **probe128_g64 顶层：`rtl\13_mega138k\board_top_probe128_g64.v`（GROUP_LANES=64 归约分组实验�?*
- **macsplit 顶层：`rtl\13_mega138k\board_top_macsplit.v` / `engine_core_macsplit.v`（MAC 阵列拆两个独�?simd_mac_array(64) + 各自归约）→ 已布�?unrouted=0**
- **完整板集成版：`rtl\13_mega138k\board_top_full_macsplit.v` / `build_full_macsplit.tcl` / `launch_full_macsplit.ps1`（full_macsplit，macsplit 结构 + LCD 完整板）�?已布�?unrouted=0，引�?Fmax=97.6MHz�?00MHz 未达�?*
- dsplit 顶层：`rtl\13_mega138k\board_top_dsplit.v` / `engine_core_dsplit.v`（数据通路拆两�?64 收敛块，MAC 阵列未拆 �?死）
- 完整顶层：`rtl\13_mega138k\board_top.v`�?28-lane + LCD�?- SDC：`rtl\13_mega138k\mega138k_engine.sdc`（三时钟 async groups）；实验�?`out\138k_pro\sweep_200m\sweep_200m.sdc`（engine_clk 5ns on `clk_200m`�?00MHz�?- 构建脚本：`rtl\13_mega138k\build_board_top.tcl`、`build_probe.tcl`、`build_sweep.tcl`（并发工作流，勿污染）；**`build_eng200.tcl`（新增，第一参数=route_option�?*
- **状态判读：`rtl\13_mega138k\watch_pnr.ps1`（新增，UTF-8 BOM�?*
- 成功 PNR 输出目录：`out\138k_pro\probe\board_top_probe\impl\pnr\`

## 8. �?合成器缺陷：两个完全相同 module 实例 �?寄存器等价合�?�?跨实例假时序路径�?026-09-02�?
**结论（已�?.vg 中逐字证实�?*：Gowin Synthesis �?*两个完全相同参数的模块实�?*（`u_mac_lo`/`u_mac_hi`，都�?`simd_mac_array(NUM_LANES=64,PIPE_MUL=1,PIPE_IN=1)`）在处理 generate 内部寄存�?`prod_pipe0`/`kx` 时做**等价寄存器合�?网共�?*，产生错误网表：

- 顶层把两侧同名端口接�?*同一条多层驱动网**：例如每�?lane �?`\gen_lane[i].gen_pipe.prod_pipe0 [7]` 同时�?u_mac_lo �?u_mac_hi �?`.gen_lane[i].gen_pipe.prod_pipe0_7` 端口（u_mac_lo 例化 L196713、u_mac_hi 例化 L199400�?*同一顶层�?*）�?- **hi 模块（simd_mac_array_0）内部没�?prod_pipe0 FF、也没有 prod_pipe0 端口声明**（prod13_p 引用=0，DFF=0），但其加法�?`.I0` 直接读该共享�?�?**�?lo 实例�?FF 驱动**�?- hi 模块加法�?**lane 索引错位**：`u_mac_hi/gen_lane[26].gen_pipe.psum_ext_7_s` �?`.I0(\gen_lane[9].gen_pipe.prod_pipe0_7)`（L136544）——lane 26 加法器读 lane 9 �?prod，I1 才是正确�?`acc_hi_839`(=lane26 bit7)�?- 这与 STA 报告 cross-instance/cross-lane 最差路�?*逐字对应**：`u_mac_lo/gen_lane[9].prod_pipe0_7_s0/Q �?u_mac_hi/gen_lane[26].psum_ext_7_s/I0`，以�?P1 `hi/gen_lane[8].kx_* �?lo/gen_lane[18].kx_pipe_8_s0`�?
**证据位置**（`board_top_macsplit_reg.vg`�?04552 行）：顶层共享网连接 L194623-196916(lo)/L199089-199400(hi)；hi 模块 lane26 加法�?L136541-548；hi 模块为零 prod FF（`\gen_lane[26].gen_pipe.prod14` �?`prod13_p` 引用）；lo 模块 lane9 FF L22470、lane26 FF L29113，加法器 lane 索引正确（L41678/L46412）�?
**影响**�?1. macsplit_reg 的时�?布线结果 **建立在下游将被合并的损坏网表�?*——Fmax 129.4 无对比意义，比特�?*功能错误**（hi 阵列累加输入被接�?lane 且来�?lo）�?2. **并非布局/布线问题** �?之前设想�?CST/pblock/布局规整化实验在损坏网表上是**徒劳**�?3. �?*单个** simd_mac_array 实例（probe/sweep/macsplit 早期 128-lane 单实例）无此问题——因为无第二个同模实例可合并�?*唯独"两个同参�?64-lane 实例"�?macsplit_reg 触发�?*

**修复方向（候选）**�?- A. 让两实例可区分：�?hi 传不同参数（�?PIPE_MUL 0/1 错开，或加激励合成器不折叠的差分），验证跨实例网是否消失�?*�?PIPE_MUL=0 会使 hi 回组合长链，仅作诊断**�?- B. �?generate/宏把 hi 复制为改名模块并**使内部网络结构拓扑略�?*，破坏等价判定（需真拓扑差，纯改名/参数无用——现 hi 已名 `simd_mac_array_0` 仍合并）�?- C. �?SUG1220/SUG113 是否�?*关闭寄存器共�?等价折叠**的合成开关（`option` / RTL 属性，�?`/* synthesis preserve */`、`syn_preserve`、`syn_keep`）�?- D. **重新审视 2×64 macsplit 方案的价�?*：既然单实例 128 �?cross-instance 假路径不存在，若布线问题是单实例 128 的全局扇出（probe128 死因），则修复双实例缺陷�?2×64 仍是正确方向�?
**下一步验证（低成本优先）**：先查合成选项能否关等价合并（C）；若无，做 A �?PIPE_MUL 差分诊断实验证明根因，再落地 B/D�?

**�޸���֤��ɣ�2026-09-02������ C �ɹ���**������ˮ�Ĵ����� /* synthesis syn_dont_touch = 1 */��kx_vld/kx_pipe/kx_sgn/prod_pipe0/prod_vld �崦����˫ʵ�� 64-lane macsplit_dontouch ʵ�� PNR ͨ����route=2/place=0, 1434s����.vg ���ֺ˶ԣ�hi ģ�� prod_pipe0 DFFRE=2048������ 0����kx_pipe DFFRE=768��lane26 �ӷ��� I0 ���Լ� lane26������ prod_pipe0 ����=0��lo/hi ���� kx ������=0 �� ��ʵ���Ĵ����ϲ�����������hi ʵ����ȫ������

**�޸�����ʵʱ�� = ��̱�**��Fmax 91.423MHz��Logic Level 5��TNS -25680��19955 endpoints����Register 14349(+3500=hi ��ˮ FF �ָ�)����ǰ macsplit_reg �� 129.4MHz �ǽ����������ϵ�ʧ��������·���䲻�ٿ�ʵ����������x_q��kx_pipe ��ʵ·�������� route ռ path 82.7%��cell �� 14.2%���� ƿ��=����/���ֳ��ߣ�lo/hi ��ʵ���������� + kx ��Ͽ���������������һ����̱����û�ָ����صĲ��ֲ��߸�Ԥ��MAX_FANOUT/CST/pblock �� lane ����/220-230MHz ԣ��Լ����Ŀ����ȷ����ѹ����>4ns ��ʵ�����ߡ�

**��������**�����Ǳ���Ŀ�� 2 ��"������"���򣨵� 1 ���� 128-lane ȫ���ȳ���ѭ������2x64 macsplit ����������������ȷ�� = ���� syn_dont_touch �޸�ȷ����Fmax 91.4 Ϊ�棬���ֲ��߸�Ԥ��Ψһȥ·��
## 9. ��Ƭð����¼ʵս���飨2026-09-02��GW5AST-138B ��壩

**��������**���޸��� macsplit_dontouch �������ۺϡ�PnR����¼�����Ƭð��ȫ��·��֤ PASS��������������ɣ���Fmax 124.3MHz��route2/place3/max_fanout100���� CST�������� LED[0] ���� 1Hz + LED[1] ����������

**��ѵ 1���� CST ? �Զ�����ȫ�����ղ�������**���� build_macsplit_dontouch.tcl δ add �κ� .cst��Gowin �Զ����� sys_clk��P4/led[0]��M22 ������ӣ�P16/J14��ȫ���������� LED ��������**���� add ���� CST**��macsplit_engine.cst��sys_clk/rst_n/led[3:0]�������� moon �ٷ� mega138k_engine.cst����P16 ���� GCLK ���չٷ��տ����ɡ�

**��ѵ 2����¼��·������**��
1) **GUI programmer.exe ��������ռ�� USB ������**��9/1 �����������ж� ID ��ʱ���� ��ɱ���̣�`Stop-Process -Id <pid>`���� IDE ��ش��ڣ�������¼��ʧ�ܡ�
2) **JTAG ���� 15MHz �� 34.6MB λ�� 20% �ж�**��exit 1���� FPGA JTAG ״̬�����ڰ���̬��ɱ����Ҳ�ⲻ��������**���Ӷϵ� 5 ��**��λ��
3) **���� 8MHz �ȶ�**��27s ���꣬exit 0��User Code 0x0000DCE6��0x00003E5B������ ð����¼Ĭ�� 8MHz������ 15MHz��

**�ɸ�����¼����**��programmer_cli.exe����
- �� SRAM����ʧ������ָ�����`--cable-index 1 -d GW5AST-138B --frequency 8 -r 2 --fsFile board_top_macsplit_reg.fs`
- Program+Verify���� `-r 4`��ֻ�� ID/״̬��`-r 0 --output idread.txt`
- cable-index��ʵ�ʰ����� **1**��Gowin USB Cable FT2CH����lot��0������ЧĿ�ꡣ������ GW5AST-138B��ID 0x0001081B��B/C ���ã���

**��ѵ 3������ϵͳ�� 6 �� LED**��J14/R26/L20/M25/N21/N23 ˿ӡ LED0-5��������ֻԼ��ǰ 4 ����LED[5]��N23������ = **δԼ�� IO Ĭ�ϵ�ƽ**���޺��ǹ��ϣ�������ȫ�ܿ��� CST ���� N21/N23���û�ѡ������״�����۲��ж���LED[0] ����=����������������������ʱ�򣩡�LED[1] ����=���� MAC ��Ƶ��ת��LED[3]/[4] ΢��=�ڲ��źţ�������Ԥ�ڡ�
# Tang Mega 138K Pro ���� I/O �ٲ飨����֤��2026-09-02��

ǧ����ȷ��ȫ�����԰弶ԭ��ͼ + �ٷ� example����ֱ������ CST Լ���������ٲ¡�

## ϵͳ
| �ź� | ���� | ˵�� |
|---|---|---|
| sys_clk | **P16** | 50MHz ������������ GCLK�����ٷ��տ����ã� |
| rst_n / S0 | **K16** | USR_KEY[0]��**���������� +1.5K ǿ����������=����**������Ч��λ |
| WS2812 (RGB) | **H16** | WS2812B-2020 ����Э�飬24bit GRB���ߵ�ƽ���� |

## ������˿ӡ S0~S3 = USR_KEY[0..3]��ȫ��ǿ�������������ͣ�
| ˿ӡ | ���� | ��ƽ |
|---|---|---|
| S0 / rst_n | **K16** | ��������=���� |
| S1 | **F15** | ��������=���� |
| S2 | **G15** | ��������=���� |
| S3 | **G16** | ��������=���� |

> key_led ������ rst_n(K16)/key0(F15)/key1(G15)��ԭ��ͼ���� USR_KEY[0..3]=K16/F15/G15/G16��

## LED������ 6 �ţ���������**�߼��͵���**��
| ˿ӡ | ���� | ��ע |
|---|---|---|
| LED[0] | **J14** | ���������ã�����֤���� |
| LED[1] | **R26** | ����������֤������ |
| LED[2] | **L20** | �����ڲ��ź� |
| LED[3] | **M25** | �����ڲ��ź� |
| LED[4] | **N21** | δԼ��ʱĬ�ϵ�ƽ�����ܳ����� |
| LED[5] | **N23** | δԼ��ʱĬ�ϵ�ƽ�����ܳ����� |

CST ģ�壺
```
IO_LOC  "led[0]" J14;   IO_PORT "led[0]" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
IO_LOC  "led[1]" R26;   ...
IO_LOC  "led[2]" L20;
IO_LOC  "led[3]" M25;
IO_LOC  "led[4]" N21;
IO_LOC  "led[5]" N23;
IO_LOC  "WS2812" H16;   IO_PORT "WS2812" IO_TYPE=LVCMOS33 PULL_MODE=NONE DRIVE=8 BANK_VCCIO=3.3;
```

## ��С����
- ���� LED0(J14)���� + LED1(R26)���� �����Ƭ��֤ macsplit ð�� PASS��
- WS2812 �� H16���ٷ����� ws2812.cst ֤ʵ����
## 2026-09-03 ȫ����ð�� - JTAG ����ʶ����ָ�����
- **����֢״��ȫ**����ֻ 15MHz �����жϻ�����������״̬�¼�ʹ�� 8MHz������ `--cable-index 1 -d GW5AST-138B --frequency 8 -r 2` ���Ҳ��**���� exit=50**��0.01s ʧ�ܣ������豸 ID 0x0001081B ��������������IDCODE ͨ�� OK���� Program ͨ��ʧ�ܣ���
- **�ؼ��б�**��ID �ܶ� + Program ����ʧ�� + ��ö����Ч = JTAG ������**ֻ�������ϵ縴λ**���ϵ� ~5s ���ϵ磩��
- **USB ��ö��(disable/enable)��Ч**��`Get-PnpDevice` / `Disable-PnpDevice` / `Enable-PnpDevice` ���Ȳ�������
- **�ϵ縴λ��Ч**���ϵ� ~5s ���ϵ��ͬһ�� 8MHz ���������ָ����ҹ����Զ���Ƶ���ᵽ 15MHz��26.5s �ɹ�������δ������˵���޸�����·����ʱ 15MHz Ҳ���ã������ص���"��¼��;�쳣/����̬"��
- **����ȷ��**��`--cable-index 1 -d GW5AST-138B --frequency 8 -r 2`����¼�ɹ� user code 0x00006733 / status 0x00026230��
- **��֤����**��board_top_periph_smoke.fs��engine 124->90MHz ���ֲ��� + LCD ���� 10MHz + WS2812 + ���� LED����sys_clk 50MHz / lcd_clk 100MHz Լ�������㡣
