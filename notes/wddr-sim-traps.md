# WDDR PHY 仿真踩坑笔记（Verilator / iverilog 实战）

> 每条都真实消耗过半小时以上排查，改代码前先过一遍。

## 1. Verilator：复位必须产生真实边沿（最重要）
**症状**：时钟链前几百纳秒动一下然后全死；`ddr_dff_s/demet_s` 等异步置位单元输出停在 0。
**原因**：TB 里 `reg rst = 1'b1;` 声明即高，**没有上升沿事件**。Verilator 零初始化 + 无事件 → 异步置位永不发生（iverilog 因 X 传播侥幸能跑）。
**修法**：复位先低几个周期再拉高：
```systemverilog
logic rst = 1'b0;
initial begin
    repeat (5) @(posedge refclk);
    rst = 1'b1;          // 这条边沿是必须的
    repeat (20) @(posedge refclk);
    rst = 1'b0;
end
```
定位手段：把可疑链拆成迷你 TB 分别用 iverilog 和 Verilator 跑对比。

## 2. 本项目全局定义了 SYNTHESIS
`wddr/ddr_global_define.vh:38` 无条件 `` `define SYNTHESIS``。
所有 `ifndef SYNTHESIS` 包着的仿真便利代码（包括原厂 loadmem task）都会被剔除。
仿真专用代码要用自定义宏（现用 `WDDR_NO_RAMLOAD`）或 plusarg 自身守卫。

## 3. 文件列表顺序：包必须在最前
Verilator 不做跨文件包依赖解析，靠命令行/文件列表顺序。
`find | sort` 会把 `ibex_core.sv` 排到 `ibex_pkg.sv` 前 → 一堆 "Reference before declaration"。
规则：pkg 文件手工列在最前，其余 sort。

## 4. Verilator 不支持 per-bit 数组实例化的非 wire 输出
`ddr_dff u_dff [DWIDTH-1:0] (.o_q(q[i]));` → UNSUPPORTED 错误。
展开成双层 generate 循环即可，语义等价（见 ddr_component_lib.sv 的 ddr_fc_dly）。

## 5. XMR 进不去被内联的模块
`u_dut.u_ctrl_plane.<signal>` 报 Can't find definition（模块被 flatten/改名）。
顶层端口网线（如 `u_dut.ref_clk`）可以。绕道方案优先级：
改 POR 默认值 > force 顶层可见网线 > --public-flat-rw。

## 6. 排查利器：双模拟器对照 + 层次化计数器
- 迷你 TB（只抽可疑单元）+ iverilog/Verilator 对跑，10 秒迭代 vs 大设计 3 分钟
- TB 里对每个时钟挂 `always @(posedge x) cnt++;` 心跳打印，死点一目了然

## 7. 杂项
- Termux：shebang 用 `/data/data/com.termux/files/usr/bin/bash`；/tmp 不可写用 `/data/data/com.termux/files/usr/tmp/opencode/`
- `VERILATOR_ROOT=/data/data/com.termux/files/verilator`（share 目录的 verilated.mk 缺 includer 时需要）
- Python 生成端口表注意 SV 整数除法：表达式里 `/` 要换 `//`，否则宽度出浮点
- 固件格式：每行 32 位二进制字符串，$readmemb 直接灌 `mem[SIZE-1:0]`

## 8. 长任务防"假死"：后台 + 进度点
前台跑 3-6 分钟构建，界面像挂死（还会拖垮交互工具）。
模式：`run_bg <名字> <命令>`——nohup 后台 + while kill -0 打进度点+耗时，
完成后报 rc 和秒数。参考 `tools/verify_wddr.sh` 的 run_bg()。
二进制新鲜度检查用 `find <src> -name '*.sv' -newer "$BIN"`，别手列文件清单
（会漏掉新改的 RTL 导致复用旧二进制，白跑一场）。

## 9. Wavious MCU 启动的隐藏开关（POR 全关）
| 寄存器 | 位 | 作用 | 现状 |
|---|---|---|---|
| CTRL CLK_CFG @0xB0000 | bit8 | MCU 时钟 CGC | POR 已开(补丁) |
| MCUTOP_CFG @0x0 | bit0 | Ibex FETCH_EN | POR 已开(补丁) |
| FSW CSP_1_CFG @0xA0030 | bit8 | CLK_DISABLE_OVR_VAL 强制通道时钟禁用 | POR 已清(补丁) |
| GPB 绑带 i_gpb[2:0] | 0/1/2 | PI_EN / DIV_RST_N / SWITCH_DONE | TB 驱动 0b0111 |
| MCUTOP_CFG | bit1? | debug_req | 未开 |
| NUM_DQ=1 参数 | — | SELRANGE 越界，Wavious RTL 不支持 NUM_DQ<2 | 矩阵实测确认 |
外部 AHB 口写不到这些 CSR（解码范围限制），真实流程走 JTAG；仿真里用 POR 补丁绕过。
