// macsplit_timing.sdc — 纯引擎 macsplit 时序验证版（无 LCD 时钟）
// 目的：验证 engine_core_macsplit 输入级流水打断后，200MHz 是否可收敛。
// 时钟源：board_top_macsplit 仅 sys_clk(50MHz) + Gowin_PLL_X200 → clk_200m。

// 板载 50MHz 振荡器（物理时钟源）
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]

// 引擎 200MHz（PLL_X200.clkout0）
create_clock -name engine_clk_200 -period 5 -waveform {0 2.5} [get_nets {clk_200m}]

// 异步时钟域声明：sys 与 engine 独立
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {engine_clk_200}]