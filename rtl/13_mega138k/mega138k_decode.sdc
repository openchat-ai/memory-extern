// mega138k_decode.sdc — board_decode_top 专用时序约束
// 依据 PC-BURN-M25.md 执行序 step 1: "make .sdc: sys_clk 50MHz create_clock"
//
// 与 mega138k_engine.sdc 的区别（不要混用）:
//   mega138k_engine.sdc 声明 engine_clk_200(5ns) 与 lcd_clk_35，均挂在 PLL 输出网
//   clk_200m / clk_d 上。board_decode_top **不例化任何 PLL**（sys_clk 50MHz 直连），
//   用那份会把时钟约束挂到不存在的网，STA 结果不可信。
//
// board_decode_top 只有一个时钟域：sys_clk 50MHz 直连板载振荡器 (P16)。
// uart_rx 是异步输入 (调试器发来的串口数据), 与 sys_clk 无相位关系 → 假路径,
// 否则 STA 会把它当成需要 20ns 约束的同步输入 (实际由 uart_rx 内部中点采样处理)。

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]

set_false_path -from [get_ports {uart_rx}]

// LCD 像素钟: PLL 50M→35M (50×21/1/30) → 28.571ns
// 注意: Gowin 综合会把长网名截断重命名 (lcd_clk_35 → lcd_clk_d), 约束要写
//   综合后的名字, 否则 TA2003 "Can't set timing constraint to object"。
//   (引擎板 mega138k_engine.sdc 写的就是 lcd_clk_d)
// act_cnt/sum_out/engine_busy 从 50MHz 域同步过来 (驱动内两级同步), 与像素钟异步。
create_clock -name lcd_clk_35 -period 28.571 -waveform {0 14.2855} [get_nets {lcd_clk_d}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {lcd_clk_35}]