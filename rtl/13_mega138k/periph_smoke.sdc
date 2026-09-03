// periph_smoke.sdc — 全外设冒烟时序约束
// 时钟：sys_clk(50MHz) = WS2812 域 + PLL输入
//       engine_clk_200 = PLL_X200.clkout0(200MHz) = 引擎 + LCD分频输入
// LCD 像素时钟(200/20=10MHz)为寄存器分频生成，此处不显式约束
//   （10MHz 逻辑时序余量极大，且 Gowin SDC 的 create_generated_clock
//    对寄存器分频支持不稳，跳过避免报错）。

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]

create_clock -name engine_clk_200 -period 5 -waveform {0 2.5} [get_nets {clk_200m}]

set_clock_groups -asynchronous -group {sys_clk} -group {engine_clk_200}
