// mega138k_engine.sdc — 200MHz 引擎双时钟约束
//
// 背景：此前发现 PNR 默认 -global_freq 100MHz 对完整 128-lane engine
//       长组合路径不可达，导致布线死循环。根因是 simd_mac_array 的单拍
//       累加组合链过长（kx→取负→48bit加法→acc 全在一拍）。
//
// 解决方案（正式接入）：
//   1. RTL：simd_mac_array 增加 PIPE_MUL 参数打断关键路径（乘积锁存一拍
//      + 累加一拍），每段仅约 5-6 LUT 级。
//   2. 时钟：新增 PLL X200（50MHz → 200MHz，VCO=800/ODIV0=4），引擎跑 200MHz。
//   3. 约束：本文件声明 200MHz 引擎时钟 + 35MHz LCD 像素时钟双时钟。
//
// 频率目标：sys 50MHz(板载) → 引擎 200MHz + LCD 35MHz。

// 板载 50MHz 振荡器（物理时钟源）
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]

// 引擎 200MHz（PLL_X200.clkout0，VCO=800MHz / ODIV0=4）
create_clock -name engine_clk_200 -period 5 -waveform {0 2.5} [get_nets {clk_200m}]

// LCD 像素时钟 35MHz（PLL.clkout0，VCO=1050MHz / ODIV0=30）
create_clock -name lcd_clk_35 -period 28.571 -waveform {0 14.2855} [get_nets {lcd_clk_d}]

// ------------------------------------------------------------------
// 异步时钟域声明：引擎200MHz / LCD35MHz / sys50MHz 相互异步
//   三个 PLL/外部时钟是独立的，Gowin STA 默认对所有时钟做跨域分析，
//   会把 act_cnt[23:0]/sum_out[31:0]/engine_busy 等 CDC 路径当真实时序追，
//   徒增布线负担并可能把布线器拖进不可收敛的循环。
//   硬件上也确实是异步域（各自 lock），故显式声明为 async 组。
// ------------------------------------------------------------------
set_clock_group -asynchronous \
    -group [get_clocks {sys_clk}] \
    -group [get_clocks {engine_clk_200 lcd_clk_35}]