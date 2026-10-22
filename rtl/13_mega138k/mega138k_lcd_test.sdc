// mega138k_lcd_test.sdc — board_lcd_test 时序约束
// 注意: Gowin 综合会把长网名截断重命名 (lcd_clk_35 → lcd_clk_d),
//   create_clock 必须写**综合后**的名字, 否则 TA2003 "Can't set timing constraint to object"。
create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name lcd_clk_35 -period 28.571 -waveform {0 14.2855} [get_nets {lcd_clk_d}]
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {lcd_clk_35}]
