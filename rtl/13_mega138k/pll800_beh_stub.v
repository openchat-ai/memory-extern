// pll800_beh_stub — termux 侧行为哨兵 stun:Gowin_PLL_X800.
// termux 无 PLL 实体(PLL-X800 真件 $PLD ASIC 域); 本 stub 仅供哨兵逻辑 tb 使用,
// 物理 800 可行性只由 PC 真硅(PLL-X800 实体 + fabric 800MHz 哨兵)定, 不在 termux。
module Gowin_PLL_X800(clkout0, lock, clkin);
output wire clkout0, lock;
input  wire clkin;
reg r_clk = 0;
reg r_lock = 0;
always #0.625 r_clk = ~r_clk;            // 800MHz 行为拍
always @(posedge clkin) r_lock <= 1;     // 模拟 lock: 首拍后恒 1
assign clkout0 = r_clk;
assign lock    = r_lock;
endmodule
