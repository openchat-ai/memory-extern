`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// gowin_pll_model.v — Gowin_PLL 的**仿真替身** (只给 iverilog 用)
// 真模块 gowin_pll.v 实例化的是 Gowin 原厂 PLL 原语 (PLL), iverilog 不认,
//   故仿真时用本文件替代 (直通时钟)。
// 注意: 真综合必须用 rtl/13_mega138k/gowin_pll.v, 别用本文件。
//────────────────────────────────────────────────────────────────────────────
module Gowin_PLL (clkout0, lock, clkin);
    output clkout0;
    output lock;
    input  clkin;

    assign clkout0 = clkin;   // 仿真直通 (真实: 50M → 35M, 50×21/1/30)
    assign lock    = 1'b1;
endmodule
`default_nettype wire
