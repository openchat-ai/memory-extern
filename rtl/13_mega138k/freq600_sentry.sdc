// freq600_sentry.sdc — 600 哨兵双时钟约束
// sys 50MHz(板载) → PLL-X600 clkout0=600MHz → 哨兵 cnt 计数域
// 600 域(1.667ns)与 50 域(20ns)为异步域, 显式分组防 STA 追 CDC

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name clk_600 -period 1.667 -waveform {0 0.833} [get_nets {clk_600}]

set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_600}]