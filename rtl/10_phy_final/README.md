# Wavious WDDR PHY 适配版 — 当前状态与操作手册

> 更新：2026-08-22。本文是唯一权威入口，改动本目录后必须同步更新这里。

## 一键命令

```bash
# 静态检查（341 模块，0 error / 0 warning，约 1 分钟）
tools/lint_wddr.sh

# 冒烟仿真（Ibex 从 TCM 启动执行固件，构建约 3-5 分钟 + 运行 1 秒）
tools/sim_wddr.sh
# 判定行：SMOKE RESULT: PASS - MCU fetched and executed from TCM
```

## 目录结构

| 目录 | 内容 | 状态 |
|---|---|---|
| `wddr/` | PHY 核心 RTL（Wavious 原始） | lint 通过 |
| `wphy_stubs/` | 模拟 IP **行为级**替身（见下） | 自研 |
| `ibex/` | RISC-V 核（lowRISC Ibex） | 原样 |
| `mcu_ibex/` | MCU 子系统（TCM/AHB/CSR） | 原样 |
| `ahb/` `component/` `tech/` | 总线/组件/工艺库 | 原样+少量补丁 |
| `sw/tests/wddr_boot/ramfiles/` | MCU 固件（itcm/dtcm b0-b7，二进制格式） | 原厂 |
| `tb/wddr_smoke_tb.sv` | 冒烟 testbench | 自研 |

## 脚本与工具

| 文件 | 作用 |
|---|---|
| **`tools/verify_wddr.sh`** | **日常入口**：lint+构建+仿真一键跑，后台进度点，汇总写 `verify_report.txt`。参数：`quick`(只lint)/`sim`(跳过lint) |
| `tools/lint_matrix.sh` | 参数矩阵 lint（default/secondary_phy/num_ch1/num_dq1 四组），结果追加报告 |
| `tools/lint_wddr.sh` | 生成 `.filelist.txt` 并跑 Verilator lint（被 verify 调用） |
| `tools/sim_wddr.sh` | 构建+运行；支持 `--build-only`、`--trace`（被 verify 调用） |
| `verify_report.txt` | 每次运行的历史追加记录（对比改动效果用） |
| `.filelist.txt` / `.filelist_sim.txt` | 自动生成勿手改；**包文件必须在最前**（Verilator 不自动解析包依赖） |
| `rtl/11_phy_complete/` | 另一条线的自研简化 DDR5 PHY（独立可跑），见其 README |

历史辅助脚本（仓库根目录，一次性生成器，已被上述行为级 stub 取代，仅存档）：
`gen_stubs.py` / `gen_stubs2.py` / `gen_stubs3.py`（从原厂黑盒 .sv 提取端口生成 tie-off stub，
gen_stubs3 是最终可用版）、`check_bodies.py`（stub 体校验）、`extract_ports.sh`（端口提取）。

## 模拟 IP 替身（wphy_stubs/wphy_all_stubs.v）

原厂模拟单元从未开源（黑盒）。现版本为**行为级**（非纯 tie-off）：

- CGC 门控 = 与门+反相；GFCM = 选择+使能
- clk_div_2ph/4ph = bypass 直通或各相位独立 ÷2 触发器
- `wphy_rpll_mvp_4g` = 使能后输出 refclk 派生 VCO 时钟（正交相用 `#10ns` 延迟近似）
- `mvp_pll_dig` = 零等待 AHB slave、永远 ready、上电即开所有 VCO、**忽略 core_reset**
- pad 驱动器 TX→RX 环回（读路径可见写数据）
- `cmn_clks_svt.pll0_div_clk` 改为**输出**（全设计唯一驱动源）
- 端口表与原黑盒一致（除上述方向修正）；tie-off 纯净版在 git 历史

## 对开源 RTL 的补丁清单（均为最小改动，搜索 "SIM-BRINGUP" 可定位）

1. `component/wav_component_lib.sv` → `wav_ram_sp`：加 `+RAMDIR=<dir>` 固件自动加载。
   从 `%m` 层次路径推导 `{itcm|dtcm}_2048x4_tcm0_b<N>_byte03_byte00.ram`。
   守卫宏用自定义 `WDDR_NO_RAMLOAD`——**本项目全局定义了 SYNTHESIS，不能用 `ifndef SYNTHESIS`！**
2. `wddr/ddr_component_lib.sv` → `ddr_fc_dly`：SV 数组实例化展开为显式 generate 循环（Verilator 不支持非 wire 输出的 per-bit 实例数组）。
3. `wddr/ddr_ctrl_csr_defs.vh`：`CLK_CFG_POR = 0x308→0x318`（bit8 MCU_CLK_CGC_EN 上电即开，否则 MCU 无时钟）。
4. `mcu_ibex/wav_mcutop_csr_defs.vh`：`MCUTOP_CFG_POR = 0x0→0x1`（FETCH_EN 上电即开，否则核不取指）。
5. `wphy_stubs/wphy_all_stubs.v` → PI_4g / pi_dly_match / prog_dly_*：**忽略 ena 直通**
   （几十个 PI 使能位 POR 全关，逐个改不现实；数据通路仿真先行）。
6. `wddr/ddr_fsw_csr_defs.vh`：`CSP_1_CFG_POR = 0x100→0x000`（清 CLK_DISABLE_OVR_VAL，
   否则通道时钟被强制禁用）。
7. `wddr/ddr_dp.sv` ~1594：u_dp_dqs 的 `i_rdqs_clk_0/180`、`i_rx_sdr_clk` 由 `'0` 改接
   PLL 相位（真实 RDQS 来自黑盒模拟 RX CC；读闭环还差 DRAM 端选通，见已验证结论）。
8. TB 驱动 GPB 绑带 `gpb=0b0111`（PI_EN/DIV_RST_N/SWITCH_DONE——真实硬件由板上拉带设置）。

## 冒烟 TB 要点（tb/wddr_smoke_tb.sv）

- 268 个端口由脚本按名字模式生成连接（rst/refclk/jtag/DFI idle 等）
- **复位必须先低后高产生真实边沿**（Verilator 零初始化 + 异步置位单元的坑，详见 notes/wddr-sim-traps.md）
- 监控：`u_dut.u_mcu.u_ibex_core.pc_if`、`instr_req_o`、时钟边沿计数、`o_gpb`
- 通过判据：pc_changes>100 且 instr_req>100

## 已验证结论（2026-08-22 终态）

- lint 全绿；`tools/verify_wddr.sh` 一键复现：MCU 启动 PASS（pc_changes≈135K、instr_req≈28K）
- **时钟树全通**：vco0 → o_pll_clk 四相 → ch0_phy_clk → o_dfi_clk 各 7.4 万沿。
  关键修复：① cmn_clks_svt 的 phy_clk0..270 输入→输出（它是唯一驱动源）；
  ② 行为级 PI/prog_dly 忽略 ena 直通；③ FSW CSP_1_CFG POR 清 CLK_DISABLE_OVR_VAL；
  ④ GPB 绑带 bit0/1/2=1（PI_EN/DIV_RST_N/SWITCH_DONE）
- mini-DFI 控制器在 TB 跑写/读突发：**写路径确认活**（dfiwr 时钟 7.4 万沿）
- 固件真实进度：复位→BSS→IRQ→重配 CLK_CFG(0x319)→配 PLL(0x98000)→FSW 切换(0xa0000)
  →轮询 0x98010（黑盒 IP 寄存器语义未知，硬边界）
- **读闭环未达**，断点两层：① ddp u_dp_dqs 的 rdqs/rx_sdr '0 绑定已改接 PLL（本轮）；
  ② DQ 侧 FIFO 的 rx_sdr_clk 仍经 NO_RX_CC 直通取自上层接线——收尾需伪造 DRAM 端
  RDQS 选通时序（mini-DRAM 模型），多天级工作
- 外部 AHB 口只能到 MCU TCM/MCUTOP；PHY CTRL/CMN CSR 需走 JTAG 或固件


## 离线工作流（零流量用法）

```bash
tools/verify_wddr.sh        # 改完代码后跑这个（全流程 ~5-8 分钟，有进度点）
tools/lint_matrix.sh        # 动了参数相关的东西再跑（~4 分钟）
tail -20 verify_report.txt  # 看历史对比哪次改动有效
```

结果判读：

| 报告尾行 | 含义 | 动作 |
|---|---|---|
| lint/build FAIL | RTL/stub 编译问题 | 把报告里的前 5 条错误贴给助手（几 KB） |
| 判定 FULL PASS | 读数据回流，闭环达成 | 进入下一里程碑 |
| PASS 但无 rd_valid | 已知状态：MCU 活跃、读路径未通 | 正常，无需处理 |
| 无结果行 | 仿真崩溃 | `tail -20 $LOGDIR/run.log` 贴出 |

原则：日志全在本地 `$LOGDIR`；需要协助时只贴结论几行，不贴整份日志。

## 待办

- [x] PLL/FSW 链 → 黑盒边界，止步
- [x] 参数矩阵 lint → `tools/lint_matrix.sh`（default/secondary_phy/num_ch1/num_dq1，
      结果追加 verify_report.txt）
- [ ] **读数据通路收尾**：mini-DRAM 模型（RDQS 选通 + 差分对行为）。入口线索全在本文
      与 notes/wddr-sim-traps.md
- [ ] TB 诊断监视加 plusarg 开关
