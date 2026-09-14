//Copyright (C)2014-2023 Gowin Semiconductor Corporation.
//Part Number: GW5AST-LV138FPG676AES
//Device: GW5AST-138B (B)
//
// Fvco = 50MHz × MDIV(16) / IDIV(1) = 800MHz (VCO 650~1300MHz, 合法带内)
// Fout = Fvco / ODIV0(1)  = 800MHz  (800 可行性哨兵实验专用实体)
// 注: ODIV0_SEL=1(÷1) 是否被工具接受、fabric 时钟树是否承载 800,
//     由带哨兵顶层的 PnR 决定: 若 ODIV 最小限制=2 则本文件非法, 报告时回退 X400(400MHz)。

module Gowin_PLL_X800 (clkout0, lock, clkin);

output clkout0;
output lock;
input clkin;

wire lock_o;
wire clkout1_o;
wire clkout2_o;
wire clkout3_o;
wire clkout4_o;
wire clkout5_o;
wire clkout6_o;
wire clkfbout_o;
wire gw_vcc;
wire gw_gnd;

assign gw_vcc = 1'b1;
assign gw_gnd = 1'b0;
assign lock = lock_o;

PLL PLL_inst (
    .LOCK(lock_o),
    .CLKOUT0(clkout0),
    .CLKOUT1(clkout1_o),
    .CLKOUT2(clkout2_o),
    .CLKOUT3(clkout3_o),
    .CLKOUT4(clkout4_o),
    .CLKOUT5(clkout5_o),
    .CLKOUT6(clkout6_o),
    .CLKFBOUT(clkfbout_o),
    .CLKIN(clkin),
    .RESET(gw_gnd),
    .RESET_P(gw_gnd),
    .FBDSEL({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
    .IDSEL({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0}),
    .DIVSEL({1'b0,1'b0,1'b0}),
    .ENCLKOUT0(1'b1),
    .DSM(1'b0)
);

defparam PLL_inst.DYN_SDIV_SEL = "TRUE";
defparam PLL_inst.DYN_FBDIV_SEL = "TRUE";
defparam PLL_inst.DYN_IDIV_SEL = "TRUE";
defparam PLL_inst.DYN_ODIV0_SEL = "FALSE";
defparam PLL_inst.DYN_ODIV1_SEL = "FALSE";
defparam PLL_inst.DYN_ODIV2_SEL = "FALSE";
defparam PLL_inst.DYN_ODIV3_SEL = "FALSE";
defparam PLL_inst.DYN_ODIV4_SEL = "FALSE";
defparam PLL_inst.DYN_ODIV5_SEL = "FALSE";
defparam PLL_inst.DYN_ODIV6_SEL = "FALSE";
defparam PLL_inst.DYN_ORP_EN = "FALSE";
defparam PLL_inst.DYN_DPA_EN = "FALSE";
defparam PLL_inst.DYN_DRPA_EN = "FALSE";
defparam PLL_inst.DYN_DPA_DIV0_SEL = "1";
defparam PLL_inst.DYN_RSTN_SEL = "FALSE";
defparam PLL_inst.CLKOUT0_EN = "TRUE";
defparam PLL_inst.CLKOUT1_EN = "FALSE";
defparam PLL_inst.CLKOUT2_EN = "FALSE";
defparam PLL_inst.CLKOUT3_EN = "FALSE";
defparam PLL_inst.CLKOUT4_EN = "FALSE";
defparam PLL_inst.CLKOUT5_EN = "FALSE";
defparam PLL_inst.CLKOUT6_EN = "FALSE";
defparam PLL_inst.FCLKIN = "50";
defparam PLL_inst.ODIV0_SEL = 1;        // Fout = 800/1 = 800MHz
defparam PLL_inst.ODIV0_FRAC_SEL = 0;
defparam PLL_inst.ODIV1_SEL = 8;
defparam PLL_inst.ODIV1_FRAC_SEL = 0;
defparam PLL_inst.ODIV2_SEL = 8;
defparam PLL_inst.ODIV2_FRAC_SEL = 0;
defparam PLL_inst.ODIV3_SEL = 8;
defparam PLL_inst.ODIV3_FRAC_SEL = 0;
defparam PLL_inst.ODIV4_SEL = 8;
defparam PLL_inst.ODIV4_FRAC_SEL = 0;
defparam PLL_inst.ODIV5_SEL = 8;
defparam PLL_inst.ODIV5_FRAC_SEL = 0;
defparam PLL_inst.ODIV6_SEL = 8;
defparam PLL_inst.ODIV6_FRAC_SEL = 0;
defparam PLL_inst.CLK_FB_SEL = "INTERNAL";
defparam PLL_inst.IDIV_SEL = 1;         // 50 / 1 = 50
defparam PLL_inst.FBDIV_SEL = 16;       // 50 × 16 / 1 = 800 (VCO)
defparam PLL_inst.MDIV_SEL = 16;
defparam PLL_inst.SDIV_SEL = 8;
defparam PLL_inst.CLKOUT0_SYN = "FALSE";
defparam PLL_inst.CLKOUT0_PHASE = "0.0";
defparam PLL_inst.CLKOUT0_DS = "FALSE";
defparam PLL_inst.CLKOUT0_DPA_DIV = "1";
defparam PLL_inst.CLKOUT0_DIV = "1";    // 800/div0
defparam PLL_inst.CLKFBOUT_SYN = "FALSE";
defparam PLL_inst.CLKFBOUT_DS = "FALSE";
defparam PLL_inst.CLKFBOUT_PHASE = "0.0";
defparam PLL_inst.DYNAMIC_SDIV = 8;
defparam PLL_inst.DYNAMIC_FBDIV = 16;
defparam PLL_inst.DYNAMIC_IDIV = 1;
defparam PLL_inst.GRS_EN = "FALSE";
defparam PLL_inst.LOCK_MODE = "0";
defparam PLL_inst.STARTUP_WAIT = "FALSE";

endmodule //Gowin_PLL_X800