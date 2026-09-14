`default_nettype none
// board_freq800_sentry — 800 哨兵板级顶层
// PLL-X800(50M→800M) + freq800_sentry_top; 三观测点:
//   led_lock = J14(LED0)  [DOC 原定 L25 为自由 GPIO 非板载 LED, 已改真实 LED]
//   led_slow = M25(LED3)  800 域计数翻转
//   led_go   = R26(LED1)
module board_freq800_sentry (
    input  wire sys_clk,
    input  wire rst_n,
    output wire led_lock,
    output wire led_slow,
    output wire led_go
);
wire clk_800;
wire pll_lock;

Gowin_PLL_X800 u_pll (
    .clkout0(clk_800),
    .lock   (pll_lock),
    .clkin  (sys_clk)
);

wire led_lock_i, led_slow_i, led_go_i;

freq800_sentry_top #(
    .SLOWLOG(5)
) u_sentry (
    .clk_800 (clk_800),
    .clk_50  (sys_clk),
    .rst_n   (rst_n),
    .pll_lock(pll_lock),
    .led_lock(led_lock_i),
    .led_slow(led_slow_i),
    .led_go  (led_go_i)
);

// LED 共阳低亮: 逻辑 1(锁定时) 需取反驱动 → 锁定时恒亮; slow 翻转不受极性影响
assign led_lock = ~led_lock_i;
assign led_slow = ~led_slow_i;
assign led_go   = ~led_go_i;
endmodule