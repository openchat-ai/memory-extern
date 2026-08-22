// =============================================================================
// wphy_all_stubs.v — Behavioral models for Wavious analog/mixed-signal IP
//
// The original analog cells (PLL, clock gating, dividers, PI, SA, pad drivers)
// were never open-sourced (black-box stubs only). This file provides minimal
// BEHAVIORAL replacements sufficient for digital smoke simulation:
//   * clocks propagate when enables are asserted
//   * muxes select, dividers divide, drivers loop back to receivers
// Port lists match the original stubs exactly, EXCEPT:
//   * wphy_lp4x5_cmn_clks_svt.pll0_div_clk is an OUTPUT here (it drives
//     ddr_cmn_wrapper.o_pll0_div_clk; nothing else drives that net).
//
// For silicon bring-up these must be replaced by foundry IP.
// Tie-off-only versions are archived in tools/ history (git).
// =============================================================================

`timescale 1ns/1ps

// Quadrature delay: quarter period of the ~24-26MHz refclk used in sim TBs.
// Phase accuracy is irrelevant for digital smoke tests; edges just need to exist.
parameter time WPHY_PH_DELAY = 10ns;

// -----------------------------------------------------------------------------
// Serializer 2:1 mux (14G)
// -----------------------------------------------------------------------------
module wphy_2to1_14g_rvt (
    output o_z,
    input i_clk,
    input i_clk_b,
    input i_dataf,
    input i_datar,
    inout vdda,
    inout vss
);
    assign o_z = i_clk ? i_datar : i_dataf;
endmodule

// -----------------------------------------------------------------------------
// Clock gate cells (diff pairs): gated clock + complement
// -----------------------------------------------------------------------------
module wphy_cgc_diff_lvt (
    output o_clk,
    output o_clk_b,
    input ena,
    input i_clk,
    input i_clk_b,
    inout vdd,
    inout vss
);
    wire g = i_clk & ena;
    assign o_clk   = g;
    assign o_clk_b = ~g;
endmodule

module wphy_cgc_diff_rh_lvt (
    output o_clk,
    output o_clk_b,
    input ena,
    input i_clk,
    input i_clk_b,
    inout vdd,
    inout vss
);
    wire g = i_clk & ena;
    assign o_clk   = g;
    assign o_clk_b = ~g;
endmodule

module wphy_cgc_diff_rh_svt (
    output o_clk,
    output o_clk_b,
    input ena,
    input i_clk,
    input i_clk_b,
    inout vdd,
    inout vss
);
    wire g = i_clk & ena;
    assign o_clk   = g;
    assign o_clk_b = ~g;
endmodule

module wphy_cgc_diff_svt (
    output o_clk,
    output o_clk_b,
    input ena,
    input i_clk,
    input i_clk_b,
    inout vdd,
    inout vss
);
    wire g = i_clk & ena;
    assign o_clk   = g;
    assign o_clk_b = ~g;
endmodule

// -----------------------------------------------------------------------------
// Clock dividers: bypass passthrough, else divide-by-2 flops per phase
// -----------------------------------------------------------------------------
module wphy_clk_div_2ph_4g_dlymatch_lvt (
    output o_clk0,
    output o_clk180,
    input i_byp,
    input i_clk0,
    input i_clk180,
    inout vdda,
    inout vss
);
    reg q;
    always @(posedge i_clk0) q <= ~q;
    assign o_clk0   = i_byp ? i_clk0   : q;
    assign o_clk180 = i_byp ? i_clk180 : ~q;
endmodule

module wphy_clk_div_2ph_4g_dlymatch_svt (
    output o_clk0,
    output o_clk180,
    input i_byp,
    input i_clk0,
    input i_clk180,
    inout vdda,
    inout vss
);
    reg q;
    always @(posedge i_clk0) q <= ~q;
    assign o_clk0   = i_byp ? i_clk0   : q;
    assign o_clk180 = i_byp ? i_clk180 : ~q;
endmodule

module wphy_clk_div_2ph_4g_lvt (
    output o_clk0,
    output o_clk180,
    input i_byp,
    input i_clk0,
    input i_clk180,
    input i_rst,
    inout vdda,
    inout vss
);
    reg q;
    always @(posedge i_clk0 or posedge i_rst) if (i_rst) q <= 1'b0; else q <= ~q;
    assign o_clk0   = i_byp ? i_clk0   : q;
    assign o_clk180 = i_byp ? i_clk180 : ~q;
endmodule

module wphy_clk_div_2ph_4g_svt (
    output o_clk0,
    output o_clk180,
    input i_byp,
    input i_clk0,
    input i_clk180,
    input i_rst,
    inout vdda,
    inout vss
);
    reg q;
    always @(posedge i_clk0 or posedge i_rst) if (i_rst) q <= 1'b0; else q <= ~q;
    assign o_clk0   = i_byp ? i_clk0   : q;
    assign o_clk180 = i_byp ? i_clk180 : ~q;
endmodule

module wphy_clk_div_4ph_10g_dlymatch_svt (
    output o_clk0,
    output o_clk90,
    output o_clk180,
    output o_clk270,
    input i_byp,
    input i_clk0,
    input i_clk90,
    input i_clk180,
    input i_clk270,
    inout vdda,
    inout vss
);
    reg q;
    always @(posedge i_clk0) q <= ~q;
    assign o_clk0   = i_byp ? i_clk0   : q;
    assign o_clk90  = i_byp ? i_clk90  : ~q;
    assign o_clk180 = i_byp ? i_clk180 : q;
    assign o_clk270 = i_byp ? i_clk270 : ~q;
endmodule

module wphy_clk_div_4ph_10g_svt (
    output o_clk0,
    output o_clk90,
    output o_clk180,
    output o_clk270,
    input i_byp,
    input i_clk0,
    input i_clk90,
    input i_clk180,
    input i_clk270,
    input i_rst,
    inout vdda,
    inout vss
);
    reg q;
    always @(posedge i_clk0 or posedge i_rst) if (i_rst) q <= 1'b0; else q <= ~q;
    assign o_clk0   = i_byp ? i_clk0   : q;
    assign o_clk90  = i_byp ? i_clk90  : ~q;
    assign o_clk180 = i_byp ? i_clk180 : q;
    assign o_clk270 = i_byp ? i_clk270 : ~q;
endmodule

// -----------------------------------------------------------------------------
// Clock multiplexers
// -----------------------------------------------------------------------------
module wphy_clkmux_3to1_diff (
    output out_c,
    output out_t,
    input in01_c,
    input in01_t,
    input in10_c,
    input in10_t,
    input in11_c,
    input in11_t,
    input [1:0]  s,
    inout vdda,
    inout vss
);
    assign out_c = (s == 2'b01) ? in01_c :
                   (s == 2'b10) ? in10_c : in11_c;
    assign out_t = (s == 2'b01) ? in01_t :
                   (s == 2'b10) ? in10_t : in11_t;
endmodule

module wphy_clkmux_3to1_diff_slvt (
    output out_c,
    output out_t,
    input in01_c,
    input in01_t,
    input in10_c,
    input in10_t,
    input in11_c,
    input in11_t,
    input [1:0]  s,
    inout vdda,
    inout vss
);
    assign out_c = (s == 2'b01) ? in01_c :
                   (s == 2'b10) ? in10_c : in11_c;
    assign out_t = (s == 2'b01) ? in01_t :
                   (s == 2'b10) ? in10_t : in11_t;
endmodule

module wphy_clkmux_diff (
    output d_ddrclk_c,
    output d_ddrclk_t,
    output d_qdrclk_c,
    output d_qdrclk_t,
    input [1:0]  d_ddrclk_sel,
    input d_pi0,
    input d_pi90,
    input d_pi180,
    input d_pi270,
    input d_qclk1_c,
    input d_qclk1_t,
    input d_qclk2_c,
    input d_qclk2_t,
    input [1:0]  d_qdrclk_sel,
    input d_rdqs_c,
    input d_rdqs_t,
    input d_wck_c,
    input d_wck_t,
    inout vdda,
    inout vss
);
    // DDR clock: one of the four PI phases (single-ended in, diff out)
    assign d_ddrclk_c = (d_ddrclk_sel == 2'b00) ? d_pi0   :
                        (d_ddrclk_sel == 2'b01) ? d_pi90  :
                        (d_ddrclk_sel == 2'b10) ? d_pi180 : d_pi270;
    assign d_ddrclk_t = ~d_ddrclk_c;
    // QDR clock: one of two QCLK sources / RDQS / WCK
    assign d_qdrclk_c = (d_qdrclk_sel == 2'b00) ? d_qclk1_c :
                        (d_qdrclk_sel == 2'b01) ? d_qclk2_c :
                        (d_qdrclk_sel == 2'b10) ? d_rdqs_c : d_wck_c;
    assign d_qdrclk_t = (d_qdrclk_sel == 2'b00) ? d_qclk1_t :
                        (d_qdrclk_sel == 2'b01) ? d_qclk2_t :
                        (d_qdrclk_sel == 2'b10) ? d_rdqs_t : d_wck_t;
endmodule

// -----------------------------------------------------------------------------
// Global clock mesh: select + enable
// -----------------------------------------------------------------------------
module wphy_gfcm_lvt (
    output o_clk0,
    output o_clk180,
    input clk_sel,
    input ena,
    input i_clka0,
    input i_clka180,
    input i_clkb0,
    input i_clkb180,
    inout vdda,
    inout vss
);
    assign o_clk0   = ena ? (clk_sel ? i_clkb0   : i_clka0)   : 1'b0;
    assign o_clk180 = ena ? (clk_sel ? i_clkb180 : i_clka180) : 1'b0;
endmodule

module wphy_gfcm_svt (
    output o_clk0,
    output o_clk180,
    input clk_sel,
    input ena,
    input i_clka0,
    input i_clka180,
    input i_clkb0,
    input i_clkb180,
    inout vdda,
    inout vss
);
    assign o_clk0   = ena ? (clk_sel ? i_clkb0   : i_clka0)   : 1'b0;
    assign o_clk180 = ena ? (clk_sel ? i_clkb180 : i_clka180) : 1'b0;
endmodule

// -----------------------------------------------------------------------------
// Phase interpolator: quadrant-select passthrough
// -----------------------------------------------------------------------------
module wphy_pi_4g (
    output out,
    output outb,
    input clk0,
    input clk90,
    input clk180,
    input clk270,
    input [15:0]  code,
    input ena,
    input [3:0]  gear,
    input [1:0]  quad,
    input [3:0]  xcpl,
    inout vdda,
    inout vss
);
    wire sel = (quad == 2'b00) ? clk0   :
               (quad == 2'b01) ? clk90  :
               (quad == 2'b10) ? clk180 : clk270;
    // SIM-BRINGUP: ignore ena -- dozens of PI EN bits default off in CSR PORs;
    // passing through unconditionally lets the datapath run before SW init
    assign out  = sel;
    assign outb = ~sel;
endmodule

module wphy_pi_dly_match_4g (
    output out,
    output outb,
    input clk0,
    input clk180,
    input ena,
    input [3:0]  gear,
    input [3:0]  xcpl,
    inout vdda,
    inout vss
);
    assign out  = clk0;   // SIM-BRINGUP: ignore ena
    assign outb = ~clk0;
endmodule

// -----------------------------------------------------------------------------
// Programmable delay: inverter passthrough
// -----------------------------------------------------------------------------
module wphy_prog_dly_se_4g (
    output outb,
    input ena,
    input [1:0] gear,
    input [5:0] i_ctrl,
    input in,
    inout vdda,
    inout vss
);
    assign outb = ~in;    // SIM-BRINGUP: ignore ena
endmodule

module wphy_prog_dly_se_4g_small (
    output outb,
    input ena,
    input [1:0] gear,
    input [5:0] i_ctrl,
    input in,
    inout vdda,
    inout vss
);
    assign outb = ~in;    // SIM-BRINGUP: ignore ena
endmodule

// -----------------------------------------------------------------------------
// Sense amplifier: transparent when enabled
// -----------------------------------------------------------------------------
module wphy_sa_4g_2ph_pdly_no_esd (
    output d_data_c,
    output d_data_t,
    output d_datab_c,
    output d_datab_t,
    input [3:0]  d_cal_c,
    input d_cal_dir_c,
    input d_cal_dir_t,
    input [3:0]  d_cal_t,
    input d_clk_c,
    input d_clk_t,
    input [5:0]  d_dly_ctrl_c,
    input [5:0]  d_dly_ctrl_t,
    input [1:0]  d_dly_gear_c,
    input [1:0]  d_dly_gear_t,
    input d_sa_ena,
    input d_sacal_ena,
    input rxin,
    input vref,
    inout vdda,
    inout vss
);
    assign d_data_c  = d_sa_ena ? rxin  : 1'b0;
    assign d_data_t  = d_sa_ena ? rxin  : 1'b0;
    assign d_datab_c = d_sa_ena ? ~rxin : 1'b0;
    assign d_datab_t = d_sa_ena ? ~rxin : 1'b0;
endmodule

// -----------------------------------------------------------------------------
// Pad drivers / receivers: TX-to-RX loopback so read path sees written data
// -----------------------------------------------------------------------------
module wphy_lp4x5_cke_drvr_w_lpbk (
    output d_lpbk_out,
    inout pad_cke_out,
    input d_bs_din,
    input d_bs_ena,
    input d_in_c,
    input d_lpbk_ena,
    input [2:0]  d_ovrd,
    input d_ovrd_val,
    input freeze_n_hv,
    inout vdda,
    inout vdda1p2,
    inout vss
);
    assign d_lpbk_out = d_lpbk_ena & d_in_c;
endmodule

module wphy_lp4x5_cmn (
    output ddr_rstn_lpbk_out,
    output freeze_n_aon,
    output freeze_n_hv,
    output pmon_nand_fout,
    input pmon_nor_fout,
    input vref,
    input zacal_comp_out,
    inout pad_atb,
    inout pad_reset_n,
    inout pad_rext,
    input [3:0]  atst_in,
    input [3:0]  atst_sel,
    input ddr_rstn_bs_din,
    input ddr_rstn_bs_ena,
    input ddr_rstn_din,
    input ddr_rstn_lpbk_ena,
    input [2:0]  dtst_drv_impd,
    input dtst_in,
    input freeze_n,
    input [2:0]  ldo_atst_sel,
    input ldo_phy_ena,
    input ldo_phy_hiz,
    input ldo_tran_enh_ena,
    input [7:0]  ldo_vref_ctrl,
    input pmon_nand_ena,
    input pmon_nor_ena,
    input [7:0]  vref_ctrl,
    input vref_ena,
    input vref_hiz,
    input [1:0]  vref_pwr,
    input zqcal_cal_ena,
    input [4:0]  zqcal_ncal,
    input [5:0]  zqcal_pcal,
    input zqcal_pd_sel,
    input zqcal_vol_0p6_sel,
    inout vdda1p2,
    inout vddq,
    inout vdd_phy,
    inout vdd_aon,
    inout vss
);
    assign ddr_rstn_lpbk_out = ddr_rstn_lpbk_ena &  ddr_rstn_din;
    assign freeze_n_aon      = freeze_n;
    assign freeze_n_hv       = freeze_n;
    assign pmon_nand_fout    = 1'b0;
endmodule

module wphy_lp4x5_cmn_clks_svt (
    output gfcm0_clka_sel,
    output gfcm0_clkb_sel,
    output gfcm1_clka_sel,
    output gfcm1_clkb_sel,
    // NOTE: original black-box declared these as INPUTS, but nothing in
    // ddr_cmn_wrapper drives them -- this cell is their only driver.
    // Behavioral model: mux VCO1/VCO2 quadrature sets out to PHY.
    output phy_clk0,
    output phy_clk90,
    output phy_clk180,
    output phy_clk270,
    output pll0_div_clk,
    input gfcm_clksel,
    input gfcm_ena,
    input phy_clk_ena,
    input pll0_div_clk_byp,
    input pll0_div_clk_ena,
    input pll0_div_clk_rst,
    input vco1_clk0,
    input vco1_clk90,
    input vco1_clk180,
    input vco1_clk270,
    input vco2_clk0,
    input vco2_clk90,
    input vco2_clk180,
    input vco2_clk270,
    inout vdd_phy,
    inout vss
);
    // GFCM source selects follow the static configuration input
    assign gfcm0_clka_sel = ~gfcm_clksel;
    assign gfcm0_clkb_sel =  gfcm_clksel;
    assign gfcm1_clka_sel = ~gfcm_clksel;
    assign gfcm1_clkb_sel =  gfcm_clksel;

    // PHY quad clock output: VCO1 (sel=0) or VCO2 (sel=1), gated by enable
    wire        use2 = gfcm_clksel;
    wire        en_q = phy_clk_ena | gfcm_ena;
    assign phy_clk0   = en_q ? (use2 ? vco2_clk0   : vco1_clk0)   : 1'b0;
    assign phy_clk90  = en_q ? (use2 ? vco2_clk90  : vco1_clk90)  : 1'b0;
    assign phy_clk180 = en_q ? (use2 ? vco2_clk180 : vco1_clk180) : 1'b0;
    assign phy_clk270 = en_q ? (use2 ? vco2_clk270 : vco1_clk270) : 1'b0;

    // Divided PLL clock for MCU/GFCM sourcing: bypass or divide-by-2 of phy_clk0
    reg div_q;
    always @(posedge phy_clk0 or posedge pll0_div_clk_rst) begin
        if (pll0_div_clk_rst) div_q <= 1'b0;
        else                  div_q <= ~div_q;
    end
    assign pll0_div_clk = pll0_div_clk_byp ? phy_clk0 :
                          pll0_div_clk_ena ? div_q    : 1'b0;
endmodule

module wphy_lp4x5_dq_drvr_w_lpbk (
    output d_lpbk_out,
    output rx_in,
    inout pad,
    input d_bs_din,
    input d_bs_ena,
    input [2:0]  d_drv_impd,
    input d_in_c,
    input d_lpbk_ena,
    input [4:0]  d_ncal,
    input [2:0]  d_ovrd,
    input d_ovrd_val,
    input [5:0]  d_pcal,
    input freeze_n,
    inout vdda,
    inout vddq,
    inout vdd_aon,
    inout vss
);
    assign rx_in      = d_in_c;              // TX->RX loopback
    assign d_lpbk_out = d_lpbk_ena & d_in_c;
endmodule

module wphy_lp4x5_dqs_drvr_w_lpbk (
    output dqs_rx_in_c,
    output dqs_rx_in_t,
    output lpbk_out_c,
    output lpbk_out_t,
    inout pad_c,
    inout pad_t,
    input d_bs_din_c,
    input d_bs_din_t,
    input d_bs_ena,
    input [2:0]  d_drv_impd,
    input d_in_c,
    input d_lpbk_ena,
    input [4:0]  d_ncal,
    input [2:0]  d_ovrd,
    input d_ovrd_val_c,
    input d_ovrd_val_t,
    input [5:0]  d_pcal,
    input d_se_mode,
    input freeze_n,
    inout vdda,
    inout vddq,
    inout vdd_aon,
    inout vss
);
    assign dqs_rx_in_c = d_in_c;             // TX->RX loopback
    assign dqs_rx_in_t = ~d_in_c;
    assign lpbk_out_c  = d_lpbk_ena &  d_in_c;
    assign lpbk_out_t  = d_lpbk_ena & ~d_in_c;
endmodule

module wphy_lp4x5_dqs_rcvr_no_esd (
    output d_dqs_out_c,
    output d_dqs_out_t,
    input [3:0]  d_cal_n_c,
    input [3:0]  d_cal_n_t,
    input [3:0]  d_cal_p_c,
    input [3:0]  d_cal_p_t,
    input d_dcpath_ena,
    input [7:0]  d_dly_ctrl_c,
    input [7:0]  d_dly_ctrl_t,
    input d_edge_det_byp,
    input d_edge_det_ena,
    input d_edge_det_refsel,
    input d_ena,
    input [2:0]  d_fb_ena,
    input d_rxcal_ena,
    input d_se_mode,
    input dqs_in_c,
    input dqs_in_t,
    inout vdda,
    inout vddq,
    inout vss
);
    assign d_dqs_out_c = d_ena ? dqs_in_c : 1'b0;
    assign d_dqs_out_t = d_ena ? dqs_in_t : 1'b0;
endmodule

// -----------------------------------------------------------------------------
// Multi-VCO PLL (analog): refclk-derived VCO clocks when enabled
// -----------------------------------------------------------------------------
module wphy_rpll_mvp_4g (
    output fbclk,
    output refclk_out,
    output vco0_clk,
    output vco0_div2_clk,
    output vco1_clk0,
    output vco1_clk90,
    output vco1_clk180,
    output vco1_clk270,
    output vco1_div2_clk,
    output vco1_div16_clk,
    output vco2_clk0,
    output vco2_clk90,
    output vco2_clk180,
    output vco2_clk270,
    output vco2_div2_clk,
    output vco2_div16_clk,
    inout vdda,
    inout vss,
    input [3:0] bias_lvl,
    input cp_int_mode,
    input div16_ena,
    input ena,
    input [8:0] fbdiv_sel,
    input [4:0] int_ctrl,
    input [1:0] pfd_mode,
    input [1:0] prop_c_ctrl,
    input [4:0] prop_ctrl,
    input [1:0] prop_r_ctrl,
    input refclk,
    input refclk_alt,
    input reset,
    input sel_refclk_alt,
    input [5:0] vco0_band,
    input vco0_byp_clk_sel,
    input vco0_ena,
    input [5:0] vco0_fine,
    input [5:0] vco1_band,
    input vco1_byp_clk_sel,
    input vco1_ena,
    input [5:0] vco1_fine,
    input [1:0] vco1_post_div,
    input [5:0] vco2_band,
    input vco2_byp_clk_sel,
    input vco2_ena,
    input [5:0] vco2_fine,
    input [1:0] vco2_post_div,
    input [1:0] vco_sel
);
    wire run0 = ena & vco0_ena & ~reset;
    wire run1 = ena & vco1_ena & ~reset;
    wire run2 = ena & vco2_ena & ~reset;

    // VCO0: single phase (PHY "phy_clk" source)
    assign vco0_clk      = run0 ? refclk : 1'b0;
    reg  d0_q;
    always @(posedge vco0_clk) d0_q <= ~d0_q;
    assign vco0_div2_clk = d0_q;

    // VCO1: quadrature set from delayed refclk copies
    wire ref_d90;
    assign #(WPHY_PH_DELAY) ref_d90 = refclk;
    assign vco1_clk0    = run1 ? refclk       : 1'b0;
    assign vco1_clk90   = run1 ? ref_d90      : 1'b0;
    assign vco1_clk180  = run1 ? ~refclk      : 1'b0;
    assign vco1_clk270  = run1 ? ~ref_d90     : 1'b0;

    reg  d1_q;
    always @(posedge vco1_clk0) d1_q <= ~d1_q;
    assign vco1_div2_clk = d1_q;
    reg [3:0] d16_q;
    always @(posedge vco1_div2_clk) d16_q <= d16_q + 4'd1;
    assign vco1_div16_clk = d16_q[3];

    // VCO2: second quadrature set (same behavioral scheme)
    assign vco2_clk0    = run2 ? refclk       : 1'b0;
    assign vco2_clk90   = run2 ? ref_d90      : 1'b0;
    assign vco2_clk180  = run2 ? ~refclk      : 1'b0;
    assign vco2_clk270  = run2 ? ~ref_d90     : 1'b0;

    reg  d2_q;
    always @(posedge vco2_clk0) d2_q <= ~d2_q;
    assign vco2_div2_clk = d2_q;
    reg [3:0] e16_q;
    always @(posedge vco2_div2_clk) e16_q <= e16_q + 4'd1;
    assign vco2_div16_clk = e16_q[3];

    assign fbclk     = 1'b0;
    assign refclk_out = refclk;
endmodule

// -----------------------------------------------------------------------------
// PLL digital controller (mvp_pll_dig):
// AHB slave stub + always-ready + PLL auto-enabled so clocks flow at reset
// -----------------------------------------------------------------------------
module mvp_pll_dig (
    input core_scan_asyncrst_ctrl,
    input core_scan_clk,
    input core_scan_mode,
    input core_scan_in,
    output core_scan_out,
    input iddq_mode,
    input bscan_mode,
    input bscan_tck,
    input bscan_trst_n,
    input bscan_capturedr,
    input bscan_shiftdr,
    input bscan_updatedr,
    input bscan_tdi,
    output bscan_tdo,
    input hclk,
    input hreset,
    input hsel,
    input hwrite,
    input [1:0] htrans,
    input [2:0] hsize,
    input [2:0] hburst,
    input [7:0] haddr,
    input [31:0] hwdata,
    output [31:0] hrdata,
    output [1:0] hresp,
    output hready,
    input core_reset,
    input [1:0] core_vco_sel,
    input core_switch_vco,
    output core_gfcm_sel,
    output core_initial_switch_done,
    output core_ready,
    output [31:0] core_debug_bus_ctrl_status,
    output interrupt,
    output [3:0] mvp_bias_lvl,
    output mvp_bias_sel,
    output mvp_cp_int_mode,
    output mvp_en,
    input mvp_fbclk,
    output [8:0] mvp_fbdiv_sel,
    output [4:0] mvp_int_ctrl,
    output [4:0] mvp_prop_ctrl,
    output [1:0] mvp_pfd_mode,
    output [1:0] mvp_prop_c_ctrl,
    output [1:0] mvp_prop_r_ctrl,
    input mvp_refclk,
    output mvp_reset,
    output mvp_sel_refclk_alt,
    output mvp_div16_ena,
    input mvp_vco0_div2clk,
    output [5:0] mvp_vco0_band,
    output [5:0] mvp_vco0_fine,
    output mvp_vco0_byp_clk_sel,
    output mvp_vco0_ena,
    input mvp_vco1_div2clk,
    output [5:0] mvp_vco1_band,
    output [5:0] mvp_vco1_fine,
    output mvp_vco1_byp_clk_sel,
    output mvp_vco1_ena,
    output [1:0] mvp_vco1_post_div,
    input mvp_vco2_div2clk,
    output [5:0] mvp_vco2_band,
    output [5:0] mvp_vco2_fine,
    output mvp_vco2_byp_clk_sel,
    output mvp_vco2_ena,
    output [1:0] mvp_vco2_post_div,
    output [1:0] mvp_vco_sel
);
    // Minimal AHB slave: zero-wait-state; reads return all-ones so any
    // "poll until ready/lock" loop in boot firmware passes immediately
    assign hready    = 1'b1;
    assign hrdata    = 32'hFFFF_FFFF;
    assign hresp     = 2'b00;
    assign core_scan_out = 1'b0;
    assign bscan_tdo = 1'b0;

    // Behavioral lock: raise interrupt once, 256 cycles after reset release
    reg [8:0] lock_cnt;
    always @(posedge hclk or posedge hreset)
        if (hreset) lock_cnt <= 9'd0;
        else if (!lock_cnt[8]) lock_cnt <= lock_cnt + 9'd1;
    assign interrupt = (lock_cnt == 9'd256);
    assign core_ready               = 1'b1;
    assign core_initial_switch_done = 1'b1;
    assign core_gfcm_sel            = 1'b0;
    assign core_debug_bus_ctrl_status = 32'hFFFF_FFFF;

    // Analog config: enable all VCOs at reset so behavioral clocks flow
    assign mvp_en               = 1'b1;
    // Real IP latches a SW-reset request here; behavioral PLL ignores it,
    // otherwise ddr_cmn's hard-tied core_reset=1 would gate VCOs forever.
    assign mvp_reset            = 1'b0;
    assign mvp_sel_refclk_alt   = 1'b0;
    assign mvp_div16_ena        = 1'b0;
    assign mvp_bias_lvl         = 4'h0;
    assign mvp_bias_sel         = 1'b0;
    assign mvp_cp_int_mode      = 1'b0;
    assign mvp_fbdiv_sel        = 9'h0;
    assign mvp_int_ctrl         = 5'h0;
    assign mvp_prop_ctrl        = 5'h0;
    assign mvp_pfd_mode         = 2'h0;
    assign mvp_prop_c_ctrl      = 2'h0;
    assign mvp_prop_r_ctrl      = 2'h0;
    assign mvp_vco0_band        = 6'h0;
    assign mvp_vco0_fine        = 6'h0;
    assign mvp_vco0_byp_clk_sel = 1'b0;
    assign mvp_vco0_ena         = 1'b1;
    assign mvp_vco1_band        = 6'h0;
    assign mvp_vco1_fine        = 6'h0;
    assign mvp_vco1_byp_clk_sel = 1'b0;
    assign mvp_vco1_ena         = 1'b1;
    assign mvp_vco1_post_div    = 2'h0;
    assign mvp_vco2_band        = 6'h0;
    assign mvp_vco2_fine        = 6'h0;
    assign mvp_vco2_byp_clk_sel = 1'b0;
    assign mvp_vco2_ena         = 1'b1;
    assign mvp_vco2_post_div    = 2'h0;
    assign mvp_vco_sel          = 2'b01;  // select VCO1 (quadrature set)
endmodule
