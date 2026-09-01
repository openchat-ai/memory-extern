# Tang Mega 138K Pro Dock — 板子到手第一天动线

> 目标：上电 → 综合 `board_top` → 烧录 → 看到 LED 心跳（~1Hz）+ LCD 显示。
> 这是整个仓库 RTL 第一次跑到真硅片。做完这步，后面 PCIe/DMA/NVMe 桩全部有承载。
> 器件号：GW5AST-LV138FPG676AES，Device Version: **B**（IDE 里选封装 FCPBG676A，版本 B/C 都行，官方 demo 用 B）。

## 0. 接线（防呆）
- 12V DC 电源（板子必须外接电源，USB-C 不供电）。
- **断电**插好再上电；PCIe 金手指测试时主机与板子都要关机状态，别热插。
- JTAG+UART 8-pin（JST SH1.0）接 USB-C 调试口。
- 可选：Dock RGB666 屏插 LCD 口（不插也能出 LED 心跳，LCD 只是加分项）。

## 1. 工程路径（先改这行）
`build_board_top.tcl` 第 5 行写死 `set SRC F:/sram/sram/rtl/13_mega138k`——改成**你电脑上仓库的真实路径**：

```tcl
set SRC  F:/sram/sram/rtl/13_mega138k     # ← 改成你的路径，例如 D:/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/synth  # ← OUT 目录可自建
```

若你习惯 GUI：新建工程 → 器件 `GW5AST-LV138FPG676AES` → Device Vervion **B** → 把下列文件 add 进工程，顶层 = `board_top`：`board_top.v gowin_pll.v gowin_pll_x200.v lcd_display.v engine_core.v` + 12 的 `simd_mac_array.v reduction_tree.v reduce_group.v` + `mega138k_engine.cst / mega138k_engine.sdc`。但这篇就按命令行 `gw_sh` 走，GUI 步骤相同。

## 2. 综合 + PnR + 出 bitstream（命令行）
```bash
cd /your/path/to/rtl/13_mega138k
gw_sh build_board_top.tcl
```
`run all` = SYN→Place→Route→(timing)→bitstream 一气呵成。看见 `=== PNR DONE ===` 且 OUT 目录生成 `board_top.fs` 即成功（.fs=Gowin 配置位流）。

预期耗时：几分钟。若卡在 ~60% 布线进度 → 说明有拥塞/时序不可达，把卡住时的 PnR 日志尾部 + `report_route_congestion` 贴回对话，这是已知会诊场景（`build_sweep.tcl` 头注释里写过三种结果）。

## 3. 烧录
- 方法 A（命令行）：IDE 的 `Programmer` 无人值守模式：`gw_sh -tcl {jtag program; ...}`，或用 IDE 图形 Programmer 选 `board_top.fs`。
- 方法 B（GUI）：双击 Programmer → 添加 → 选 fs → Program。
- 烧录方式选 **SRAM**（掉电即丢）还是 **Flash** 都行；首次建议 SRAM 快验证。

## 4. 验收（防呆预期）
| 现象 | 判定 |
|------|------|
| LED 心跳：`led[0]`（J14）约 **1Hz 闪** | ✅ PASS（hb_cnt[26] @200MHz ≈ 1.34Hz） |
| `led[1..3]`（R26/L20/M25）为引擎活动指示 | 上电后应常亮或随 burst 变化（自由激励段） |
| Dock 屏（若接）显示 engine 状态 | ✅ PASS（LCD 35MHz PLL + RGB666） |
| 无任何 LED 运动 | 复位：按 S0（K16）重新拉起 `rst_n_int`；疑难再把现象+log 贴回 |

## 5. 结果给手机端（省流量协议）
- **不 push 大日志/.fs**（留 PC 本地 `out/138k_pro/synth/`）。
- 只提交仓库内小文本：脚本自动生成的 `board_top_result.txt`（status + 耗时）。
- 若 PnR 异常（卡 60% / WNS<0），先 `gw_sh mk_diag.tcl F:/sram/sram/out/138k_pro/synth` 生成 `diag_*.txt`（<10KB），只推这一个取证文件。
- 然后 `git add <result/diag> && git commit && git push` —— 我 `git pull` 后直接判读，不用你贴任何格式。

## 6. 这一步在整条主线里的位置
```
13 board_top (真硅片冒烟) ──→ build_sweep 200 签核 ──→ pcie_dma_engine(EP) ──→
  14 nvme_bridge/NVMe 块请求 ──→ T1 FPGA直挂NVMe(金手指+M.2转接卡, RC) = 全部目标
```
**做完 board_top 你手上的板子就不再是"没有承载的仿真物"，而是一台能跑引擎真机。**