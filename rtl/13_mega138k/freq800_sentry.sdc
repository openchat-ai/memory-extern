// freq800_sentry.sdc — 800 哨兵双时钟约束
// sys 50MHz(板载) → PLL-X800 clkout0=800MHz → 哨兵 cnt 计数域
// led_slow=cnt[5] 在 800 域直出; led_lock/go 由 pll_lock 过 50 域两级同步链
// 800 域(1.25ns)与 50 域(20ns)为异步域, 显式分组防 STA 追 CDC

create_clock -name sys_clk -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_clock -name clk_800 -period 1.25 -waveform {0 0.625} [get_nets {clk_800}]

set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {clk_800}]