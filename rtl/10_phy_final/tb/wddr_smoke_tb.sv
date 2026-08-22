// Wavious WDDR PHY smoke testbench - MCU boot verification
// Port map generated; clocks/reset/monitors hand-written.
`timescale 1ns/1ps

module wddr_smoke_tb;
    logic refclk='0, refclk_alt='0, ahb_ext_clk='0;
    logic rst=1'b0;   // start LOW: async-set flops need a real posedge later

    always #20 refclk     = ~refclk;      // 25 MHz
    always #20 refclk_alt = ~refclk_alt;
    always #10 ahb_ext_clk = ~ahb_ext_clk;

    logic [0:0] o_dfi_clk;
    logic [0:0] o_refclk_on;
    logic [0:0] o_irq;
    logic [6:0] o_gpb;
    logic [0:0] o_pll_clk_0;
    logic [0:0] o_pll_clk_90;
    logic [0:0] o_pll_clk_180;
    logic [0:0] o_pll_clk_270;
    logic [0:0] o_vco0_clk;
    logic [14:0] o_scan;
    logic [0:0] o_dtst;
    logic [0:0] o_jtag_tdo;
    logic [0:0] o_ahb_clk_on;
    logic [0:0] o_ahb_hready;
    logic [30:0] o_ahb_hrdata;
    logic [0:0] o_ahb_hresp;
    logic [30:0] o_ahb_haddr;
    logic [0:0] o_ahb_hwrite;
    logic [30:0] o_ahb_hwdata;
    logic [0:0] o_ahb_htrans;
    logic [1:0] o_ahb_hsize;
    logic [1:0] o_ahb_hburst;
    logic [0:0] o_ahb_hbusreq;
    logic [0:0] o_dfi_ctrlupd_ack;
    logic [0:0] o_dfi_phyupd_req;
    logic [0:0] o_dfi_phyupd_type;
    logic [0:0] o_dfi_init_complete;
    logic [0:0] o_dfi_phymstr_cs_state;
    logic [0:0] o_dfi_phymstr_req;
    logic [0:0] o_dfi_phymstr_state_sel;
    logic [0:0] o_dfi_phymstr_type;
    logic [0:0] o_dfi_lp_ctrl_ack;
    logic [0:0] o_dfi_lp_data_ack;
    logic [30:0] o_dfi_rddata_w0;
    logic [30:0] o_dfi_rddata_w1;
    logic [30:0] o_dfi_rddata_w2;
    logic [30:0] o_dfi_rddata_w3;
    logic [30:0] o_dfi_rddata_w4;
    logic [30:0] o_dfi_rddata_w5;
    logic [30:0] o_dfi_rddata_w6;
    logic [30:0] o_dfi_rddata_w7;
    logic [2:0] o_dfi_rddata_dbi_w0;
    logic [2:0] o_dfi_rddata_dbi_w1;
    logic [2:0] o_dfi_rddata_dbi_w2;
    logic [2:0] o_dfi_rddata_dbi_w3;
    logic [2:0] o_dfi_rddata_dbi_w4;
    logic [2:0] o_dfi_rddata_dbi_w5;
    logic [2:0] o_dfi_rddata_dbi_w6;
    logic [2:0] o_dfi_rddata_dbi_w7;
    logic [0:0] o_dfi_rddata_valid_w0;
    logic [0:0] o_dfi_rddata_valid_w1;
    logic [0:0] o_dfi_rddata_valid_w2;
    logic [0:0] o_dfi_rddata_valid_w3;
    logic [0:0] o_dfi_rddata_valid_w4;
    logic [0:0] o_dfi_rddata_valid_w5;
    logic [0:0] o_dfi_rddata_valid_w6;
    logic [0:0] o_dfi_rddata_valid_w7;
    logic [70:0] o_ch0_rx0_sdr;
    logic [7:0] o_ch0_rx0_sdr_vld;
    logic [70:0] o_ch0_rx1_sdr;
    logic [7:0] o_ch0_rx1_sdr_vld;
    logic [70:0] o_ch1_rx0_sdr;
    logic [7:0] o_ch1_rx0_sdr_vld;
    logic [70:0] o_ch1_rx1_sdr;
    logic [7:0] o_ch1_rx1_sdr_vld;
    logic [30:0] o_debug;

    ddr_phy u_dut (
        .i_phy_rst(rst),
        .i_dfi_clk_on(1'b1),
        .i_ana_refclk(refclk),
        .i_refclk(refclk),
        .i_refclk_alt(refclk_alt),
        .i_irq('0),
        .i_gpb(gpb_straps),
        .i_pll_clk_0('0),
        .i_pll_clk_90('0),
        .i_pll_clk_180('0),
        .i_pll_clk_270('0),
        .i_vco0_clk('0),
        .i_scan_mode(1'b0),
        .i_scan_clk('0),
        .i_scan_en(1'b0),
        .i_scan_freq_en('0),
        .i_scan_cgc_ctrl(1'b0),
        .i_scan_rst_ctrl(1'b0),
        .i_scan('0),
        .i_freeze_n(1'b1),
        .i_hiz_n(1'b1),
        .i_iddq_mode('0),
        .i_ret_en('0),
        .i_hs_en('0),
        .i_jtag_tck(1'b0),
        .i_jtag_trst_n(1'b0),
        .i_jtag_tms(1'b1),
        .i_jtag_tdi(1'b0),
        .i_ahb_clk(ahb_ext_clk),
        .i_ahb_rst(rst),
        .i_ahb_csr_rst(rst),
        .i_ahb_haddr(ahb_addr),
        .i_ahb_hwrite(ahb_wr),
        .i_ahb_hsel(ahb_sel),
        .i_ahb_hreadyin(1'b1),
        .i_ahb_hwdata(ahb_wdata),
        .i_ahb_htrans(ahb_trans),
        .i_ahb_hsize(ahb_size),
        .i_ahb_hburst('0),
        .i_ahb_hgrant(1'b1),
        .i_ahb_hready(1'b1),
        .i_ahb_hrdata('0),
        .i_ahb_hresp('0),
        .i_dfi_ctrlupd_req('0),
        .i_dfi_phyupd_ack('0),
        .i_dfi_freq_fsp('0),
        .i_dfi_freq_ratio('0),
        .i_dfi_frequency('0),
        .i_dfi_init_start('0),
        .i_dfi_phymstr_ack('0),
        .i_dfi_lp_ctrl_req('0),
        .i_dfi_lp_ctrl_wakeup('0),
        .i_dfi_lp_data_req('0),
        .i_dfi_lp_data_wakeup('0),
        .i_dfi_reset_n_p0(~rst),
        .i_dfi_reset_n_p1(~rst),
        .i_dfi_reset_n_p2(~rst),
        .i_dfi_reset_n_p3(~rst),
        .i_dfi_reset_n_p4(~rst),
        .i_dfi_reset_n_p5(~rst),
        .i_dfi_reset_n_p6(~rst),
        .i_dfi_reset_n_p7(~rst),
        .i_dfi_address_p0(dfi_addr_p0),
        .i_dfi_address_p1('0),
        .i_dfi_address_p2('0),
        .i_dfi_address_p3('0),
        .i_dfi_address_p4('0),
        .i_dfi_address_p5('0),
        .i_dfi_address_p6('0),
        .i_dfi_address_p7('0),
        .i_dfi_cke_p0(dfi_cke_p0),
        .i_dfi_cke_p1('0),
        .i_dfi_cke_p2('0),
        .i_dfi_cke_p3('0),
        .i_dfi_cke_p4('0),
        .i_dfi_cke_p5('0),
        .i_dfi_cke_p6('0),
        .i_dfi_cke_p7('0),
        .i_dfi_cs_p0(dfi_cs_p0),
        .i_dfi_cs_p1('0),
        .i_dfi_cs_p2('0),
        .i_dfi_cs_p3('0),
        .i_dfi_cs_p4('0),
        .i_dfi_cs_p5('0),
        .i_dfi_cs_p6('0),
        .i_dfi_cs_p7('0),
        .i_dfi_dram_clk_disable_p0('0),
        .i_dfi_dram_clk_disable_p1('0),
        .i_dfi_dram_clk_disable_p2('0),
        .i_dfi_dram_clk_disable_p3('0),
        .i_dfi_dram_clk_disable_p4('0),
        .i_dfi_dram_clk_disable_p5('0),
        .i_dfi_dram_clk_disable_p6('0),
        .i_dfi_dram_clk_disable_p7('0),
        .i_dfi_wrdata_p0(dfi_wrdata_p0),
        .i_dfi_wrdata_p1('0),
        .i_dfi_wrdata_p2('0),
        .i_dfi_wrdata_p3('0),
        .i_dfi_wrdata_p4('0),
        .i_dfi_wrdata_p5('0),
        .i_dfi_wrdata_p6('0),
        .i_dfi_wrdata_p7('0),
        .i_dfi_parity_in_p0('0),
        .i_dfi_parity_in_p1('0),
        .i_dfi_parity_in_p2('0),
        .i_dfi_parity_in_p3('0),
        .i_dfi_parity_in_p4('0),
        .i_dfi_parity_in_p5('0),
        .i_dfi_parity_in_p6('0),
        .i_dfi_parity_in_p7('0),
        .i_dfi_wrdata_cs_p0(dfi_wr_cs_p0),
        .i_dfi_wrdata_cs_p1('0),
        .i_dfi_wrdata_cs_p2('0),
        .i_dfi_wrdata_cs_p3('0),
        .i_dfi_wrdata_cs_p4('0),
        .i_dfi_wrdata_cs_p5('0),
        .i_dfi_wrdata_cs_p6('0),
        .i_dfi_wrdata_cs_p7('0),
        .i_dfi_wck_cs_p0('0),
        .i_dfi_wck_cs_p1('0),
        .i_dfi_wck_cs_p2('0),
        .i_dfi_wck_cs_p3('0),
        .i_dfi_wck_cs_p4('0),
        .i_dfi_wck_cs_p5('0),
        .i_dfi_wck_cs_p6('0),
        .i_dfi_wck_cs_p7('0),
        .i_dfi_wrdata_mask_p0('0),
        .i_dfi_wrdata_mask_p1('0),
        .i_dfi_wrdata_mask_p2('0),
        .i_dfi_wrdata_mask_p3('0),
        .i_dfi_wrdata_mask_p4('0),
        .i_dfi_wrdata_mask_p5('0),
        .i_dfi_wrdata_mask_p6('0),
        .i_dfi_wrdata_mask_p7('0),
        .i_dfi_wrdata_en_p0(dfi_wr_en_p0),
        .i_dfi_wrdata_en_p1('0),
        .i_dfi_wrdata_en_p2('0),
        .i_dfi_wrdata_en_p3('0),
        .i_dfi_wrdata_en_p4('0),
        .i_dfi_wrdata_en_p5('0),
        .i_dfi_wrdata_en_p6('0),
        .i_dfi_wrdata_en_p7('0),
        .i_dfi_wck_en_p0('0),
        .i_dfi_wck_en_p1('0),
        .i_dfi_wck_en_p2('0),
        .i_dfi_wck_en_p3('0),
        .i_dfi_wck_en_p4('0),
        .i_dfi_wck_en_p5('0),
        .i_dfi_wck_en_p6('0),
        .i_dfi_wck_en_p7('0),
        .i_dfi_wck_toggle_p0('0),
        .i_dfi_wck_toggle_p1('0),
        .i_dfi_wck_toggle_p2('0),
        .i_dfi_wck_toggle_p3('0),
        .i_dfi_wck_toggle_p4('0),
        .i_dfi_wck_toggle_p5('0),
        .i_dfi_wck_toggle_p6('0),
        .i_dfi_wck_toggle_p7('0),
        .i_dfi_rddata_cs_p0(dfii_rd_cs_p0),
        .i_dfi_rddata_cs_p1('0),
        .i_dfi_rddata_cs_p2('0),
        .i_dfi_rddata_cs_p3('0),
        .i_dfi_rddata_cs_p4('0),
        .i_dfi_rddata_cs_p5('0),
        .i_dfi_rddata_cs_p6('0),
        .i_dfi_rddata_cs_p7('0),
        .i_dfi_rddata_en_p0(dfi_rd_en_p0),
        .i_dfi_rddata_en_p1('0),
        .i_dfi_rddata_en_p2('0),
        .i_dfi_rddata_en_p3('0),
        .i_dfi_rddata_en_p4('0),
        .i_dfi_rddata_en_p5('0),
        .i_dfi_rddata_en_p6('0),
        .i_dfi_rddata_en_p7('0),
        .i_txrx_mode('0),
        .i_ch0_tx0_sdr('0),
        .i_ch0_tx_ck0_sdr('0),
        .i_ch0_tx1_sdr('0),
        .i_ch0_tx_ck1_sdr('0),
        .i_ch1_tx0_sdr('0),
        .i_ch1_tx_ck0_sdr('0),
        .i_ch1_tx1_sdr('0),
        .i_ch1_tx_ck1_sdr('0),
        .o_dfi_clk(o_dfi_clk),
        .o_refclk_on(o_refclk_on),
        .o_irq(o_irq),
        .o_gpb(o_gpb),
        .o_pll_clk_0(o_pll_clk_0),
        .o_pll_clk_90(o_pll_clk_90),
        .o_pll_clk_180(o_pll_clk_180),
        .o_pll_clk_270(o_pll_clk_270),
        .o_vco0_clk(o_vco0_clk),
        .o_scan(o_scan),
        .o_dtst(o_dtst),
        .o_jtag_tdo(o_jtag_tdo),
        .o_ahb_clk_on(o_ahb_clk_on),
        .o_ahb_hready(o_ahb_hready),
        .o_ahb_hrdata(o_ahb_hrdata),
        .o_ahb_hresp(o_ahb_hresp),
        .o_ahb_haddr(o_ahb_haddr),
        .o_ahb_hwrite(o_ahb_hwrite),
        .o_ahb_hwdata(o_ahb_hwdata),
        .o_ahb_htrans(o_ahb_htrans),
        .o_ahb_hsize(o_ahb_hsize),
        .o_ahb_hburst(o_ahb_hburst),
        .o_ahb_hbusreq(o_ahb_hbusreq),
        .o_dfi_ctrlupd_ack(o_dfi_ctrlupd_ack),
        .o_dfi_phyupd_req(o_dfi_phyupd_req),
        .o_dfi_phyupd_type(o_dfi_phyupd_type),
        .o_dfi_init_complete(o_dfi_init_complete),
        .o_dfi_phymstr_cs_state(o_dfi_phymstr_cs_state),
        .o_dfi_phymstr_req(o_dfi_phymstr_req),
        .o_dfi_phymstr_state_sel(o_dfi_phymstr_state_sel),
        .o_dfi_phymstr_type(o_dfi_phymstr_type),
        .o_dfi_lp_ctrl_ack(o_dfi_lp_ctrl_ack),
        .o_dfi_lp_data_ack(o_dfi_lp_data_ack),
        .o_dfi_rddata_w0(o_dfi_rddata_w0),
        .o_dfi_rddata_w1(o_dfi_rddata_w1),
        .o_dfi_rddata_w2(o_dfi_rddata_w2),
        .o_dfi_rddata_w3(o_dfi_rddata_w3),
        .o_dfi_rddata_w4(o_dfi_rddata_w4),
        .o_dfi_rddata_w5(o_dfi_rddata_w5),
        .o_dfi_rddata_w6(o_dfi_rddata_w6),
        .o_dfi_rddata_w7(o_dfi_rddata_w7),
        .o_dfi_rddata_dbi_w0(o_dfi_rddata_dbi_w0),
        .o_dfi_rddata_dbi_w1(o_dfi_rddata_dbi_w1),
        .o_dfi_rddata_dbi_w2(o_dfi_rddata_dbi_w2),
        .o_dfi_rddata_dbi_w3(o_dfi_rddata_dbi_w3),
        .o_dfi_rddata_dbi_w4(o_dfi_rddata_dbi_w4),
        .o_dfi_rddata_dbi_w5(o_dfi_rddata_dbi_w5),
        .o_dfi_rddata_dbi_w6(o_dfi_rddata_dbi_w6),
        .o_dfi_rddata_dbi_w7(o_dfi_rddata_dbi_w7),
        .o_dfi_rddata_valid_w0(o_dfi_rddata_valid_w0),
        .o_dfi_rddata_valid_w1(o_dfi_rddata_valid_w1),
        .o_dfi_rddata_valid_w2(o_dfi_rddata_valid_w2),
        .o_dfi_rddata_valid_w3(o_dfi_rddata_valid_w3),
        .o_dfi_rddata_valid_w4(o_dfi_rddata_valid_w4),
        .o_dfi_rddata_valid_w5(o_dfi_rddata_valid_w5),
        .o_dfi_rddata_valid_w6(o_dfi_rddata_valid_w6),
        .o_dfi_rddata_valid_w7(o_dfi_rddata_valid_w7),
        .o_ch0_rx0_sdr(o_ch0_rx0_sdr),
        .o_ch0_rx0_sdr_vld(o_ch0_rx0_sdr_vld),
        .o_ch0_rx1_sdr(o_ch0_rx1_sdr),
        .o_ch0_rx1_sdr_vld(o_ch0_rx1_sdr_vld),
        .o_ch1_rx0_sdr(o_ch1_rx0_sdr),
        .o_ch1_rx0_sdr_vld(o_ch1_rx0_sdr_vld),
        .o_ch1_rx1_sdr(o_ch1_rx1_sdr),
        .o_ch1_rx1_sdr_vld(o_ch1_rx1_sdr_vld),
        .o_debug(o_debug)
    );

    // ------------------------------------------------------------------
    // Monitors: MCU life signs + clock activity
    // ------------------------------------------------------------------
    logic [31:0] pc_now;
    assign pc_now = u_dut.u_mcu.u_ibex_core.pc_if;

    int pc_changes = 0;
    int req_cnt    = 0;
    int dfi_clk_cnt = 0;
    logic [31:0] pc_q = '0;

    always @(posedge refclk) begin
        if (pc_now != pc_q) begin
            pc_q <= pc_now;
            if (rst == 1'b0) pc_changes++;
        end
    end

    always @(posedge u_dut.u_mcu.u_ibex_core.instr_req_o) req_cnt++;
    always @(posedge u_dut.o_dfi_clk) dfi_clk_cnt++;

    int hb = 0;
    always @(posedge refclk) begin
        hb++;
        if (hb % 2500 == 0)
            $display("[%0t ns] pc=%08h pc_chg=%0d ireq=%0d dfi_clk=%0d gpb=%02h irq=%0h | mcu_ck=%b(%0d) hclk=%b(%0d)",
                     $time, pc_now, pc_changes, req_cnt, dfi_clk_cnt, o_gpb, o_irq,
                     u_dut.mcu_clk, mcu_clk_cnt, u_dut.ahb_clk, hclk_cnt);
        $display("          mc_bursts=%0d chphy=%b(%0d) dfi_clk=%b(%0d) rdval=%0d",
                 mc_bursts, u_dut.ch0_phy_clk, chphy_cnt, o_dfi_clk, dfi_clk_cnt, rd_valid_cnt);
        $display("          dfird1=%b(%0d) dfiwr1=%b(%0d) rd_en=%b wr_en=%b",
                 u_dut.ch0_dfird_clk_1, dfird1_cnt, u_dut.ch0_dfiwr_clk_1, dfiwr1_cnt,
                 dfi_rd_en_p0, dfi_wr_en_p0);
        $display("          pll0=%b(%0d) vco0=%b(%0d) ch0_phy=%b(%0d)",
                 o_pll_clk_0, pll0_cnt, o_vco0_clk, vco0_cnt,
                 u_dut.ch0_phy_clk, chphy_cnt);
    end


    // ------------------------------------------------------------------
    // External AHB master (CSR config) + MCU clock probe
    // ------------------------------------------------------------------
    logic [31:0] ahb_addr   = '0;
    logic [31:0] ahb_wdata  = '0;
    logic        ahb_wr     = 1'b0;
    logic        ahb_sel    = 1'b0;
    logic [1:0]  ahb_trans  = 2'b00;
    logic [2:0]  ahb_size   = 3'b010;

    int mcu_clk_cnt = 0;
    int hclk_cnt = 0;
    int sref_cnt=0, smcu_cnt=0, sahbk_cnt=0;
    int pll0_cnt=0, vco0_cnt=0, chphy_cnt=0;
    always @(posedge u_dut.mcu_clk) mcu_clk_cnt++;
    always @(posedge u_dut.ahb_clk) hclk_cnt++;
    always @(posedge u_dut.ref_clk) sref_cnt++;
    always @(posedge u_dut.mcu_clk) smcu_cnt++;
    always @(posedge u_dut.ahb_clk) sahbk_cnt++;

    int dfird1_cnt=0, dfiwr1_cnt=0;
    always @(posedge u_dut.ch0_dfird_clk_1) dfird1_cnt++;
    always @(posedge u_dut.ch0_dfiwr_clk_1) dfiwr1_cnt++;
    always @(posedge o_pll_clk_0)   pll0_cnt++;
    always @(posedge o_vco0_clk)    vco0_cnt++;
    always @(posedge u_dut.ch0_phy_clk) chphy_cnt++;

    // ------------------------------------------------------------------
    // Debug: trace AHB write through interconnect (enabled during cfg)
    // ------------------------------------------------------------------
    int dbg = 0;
    always @(posedge ahb_ext_clk) if (dbg)
        $display("[dbg ext] t=%0t sel=%b tr=%b addr=%h | s2m.tr=%b s2m.addr=%h req=%b",
                 $time, ahb_sel, ahb_trans, ahb_addr,
                 u_dut.u_ahb_ic.async_intf_ahbm_htrans,
                 u_dut.u_ahb_ic.async_intf_ahbm_haddr,
                 u_dut.u_ahb_ic.async_intf_ahbm_hbusreq);
    always @(posedge u_dut.ahb_clk) if (dbg)
        $display("[dbg hclk] t=%0t intf.tr=%b intf.addr=%h int.sel=%b phy_addr=%h ctrl_sel=%b",
                 $time,
                 u_dut.u_ahb_ic.intf_ahbm_htrans, u_dut.u_ahb_ic.intf_ahbm_haddr,
                 u_dut.u_ahb_ic.int_ahbs_hsel,
                 u_dut.u_ahb_ic.phy_ahbs_haddr, u_dut.ctrl_ahbs_hsel);

    task automatic ahb_write(input [31:0] addr, input [31:0] data);
        @(posedge ahb_ext_clk);
        ahb_addr<=addr; ahb_wdata<=data; ahb_trans<=2'b10; ahb_wr<=1; ahb_sel<=1;
        @(posedge ahb_ext_clk);
        while (!o_ahb_hready) @(posedge ahb_ext_clk);
        ahb_trans<=2'b00; ahb_wr<=0; ahb_sel<=0;
    endtask

    task automatic ahb_read(input [31:0] addr, output [31:0] rdata);
        @(posedge ahb_ext_clk);
        ahb_addr<=addr; ahb_trans<=2'b10; ahb_wr<=0; ahb_sel<=1;
        @(posedge ahb_ext_clk);
        while (!o_ahb_hready) @(posedge ahb_ext_clk);
        rdata = o_ahb_hrdata;
        ahb_trans<=2'b00; ahb_sel<=0;
    endtask

    // ------------------------------------------------------------------
    // MCU AHB master bus monitor: what is firmware polling?
    // ------------------------------------------------------------------
    logic [31:0] mon_addr_q = '0;
    always @(posedge u_dut.mcu_clk) begin
        if (u_dut.mcu_ahbm_htrans == 2'b10 && !u_dut.mcu_ahbm_hwrite)
            mon_addr_q <= u_dut.mcu_ahbm_haddr;
        if (u_dut.mcu_ahbm_htrans == 2'b00 && mon_addr_q != 0)
            mon_addr_q <= '0;
    end
    int rd_cnt = 0;
    int wr_cnt = 0;
    always @(posedge u_dut.mcu_clk)
        if (u_dut.mcu_ahbm_htrans == 2'b10 && !u_dut.mcu_ahbm_hwrite) begin
            rd_cnt++;
            if (rd_cnt < 40 || rd_cnt % 200 == 0)
                $display("[BUSRD] #%0d t=%0t addr=%08h -> rdata=%08h",
                         rd_cnt, $time, u_dut.mcu_ahbm_haddr, u_dut.mcu_ahbm_hrdata);
        end

    // write monitor + stall detector on MCU master
    int wr_dtcm=0, wr_csr=0;
    always @(posedge u_dut.mcu_clk)
        if (u_dut.mcu_ahbm_htrans == 2'b10 && u_dut.mcu_ahbm_hwrite) begin
            wr_cnt++;
            if (u_dut.mcu_ahbm_haddr[31:16] == 16'h0005) wr_dtcm++;
            else begin
                wr_csr++;
                $display("[BUSWR] #%0d t=%0t addr=%08h <= %08h",
                         wr_cnt, $time, u_dut.mcu_ahbm_haddr, u_dut.mcu_ahbm_hwdata);
            end
        end

    int stall_cnt = 0;
    always @(posedge u_dut.mcu_clk) begin
        if (u_dut.mcu_ahbm_htrans[1] && !u_dut.mcu_ahbm_hready)
            stall_cnt <= stall_cnt + 1;
        else
            stall_cnt <= 0;
        if (stall_cnt == 100)
            $display("[STALL] t=%0t addr=%08h wr=%b wdata=%08h trans=%b ready stuck LOW >100 cyc",
                     $time, u_dut.mcu_ahbm_haddr, u_dut.mcu_ahbm_hwrite,
                     u_dut.mcu_ahbm_hwdata, u_dut.mcu_ahbm_htrans);
    end

    // PC histogram: where does firmware spin?
    logic [31:0] pc_keys [0:255];
    int          pc_vals [0:255];
    int          pc_n = 0;
    always @(posedge u_dut.mcu_clk) begin
        if (!rst) begin
            int idx, found;
            found = 0;
            for (idx = 0; idx < pc_n; idx++)
                if (pc_keys[idx] == u_dut.u_mcu.u_ibex_core.pc_if) begin
                    pc_vals[idx]++; found = 1; break;
                end
            if (!found && pc_n < 256) begin
                pc_keys[pc_n] = u_dut.u_mcu.u_ibex_core.pc_if;
                pc_vals[pc_n] = 1; pc_n++;
            end
        end
    end


    // ------------------------------------------------------------------
    // mini-DFI controller: GPB straps + periodic write/read traffic on p0
    // ------------------------------------------------------------------
    logic [7:0]  gpb_straps   = 8'b0000_0111;  // PI_EN|DIV_RST_N|SWITCH_DONE
    logic [1:0]  dfi_cs_p0    = 2'b01;
    logic [1:0]  dfi_cke_p0   = 2'b01;
    logic [6:0]  dfi_addr_p0  = '0;
    logic [31:0] dfi_wrdata_p0 = '0;
    logic        dfi_wr_en_p0 = 1'b0;
    logic [1:0]  dfi_wr_cs_p0 = 2'b01;
    logic        dfi_rd_en_p0 = 1'b0;
    logic [1:0]  dfii_rd_cs_p0 = 2'b01;

    int mc_cnt = 0;
    int mc_bursts = 0;
    always @(posedge refclk) begin
        if (!rst) begin
            mc_cnt <= mc_cnt + 1;
            case (mc_cnt % 200)
                0: begin dfi_wr_en_p0 <= 1'b1; mc_bursts <= mc_bursts + 1;
                         dfi_wrdata_p0 <= 32'hA5C3_0000 + mc_bursts[15:0];
                         dfi_addr_p0   <= mc_bursts[6:0]; end
                1: begin dfi_wrdata_p0 <= dfi_wrdata_p0 ^ 32'hDEAD_BEEF; end
                29: dfi_wr_en_p0 <= 1'b0;
                100: dfi_rd_en_p0 <= 1'b1;
                129: dfi_rd_en_p0 <= 1'b0;
                default: ;
            endcase
        end
    end

    // read return monitor
    int rd_valid_cnt = 0;
    logic [31:0] last_rd = '0;
    always @(posedge o_dfi_clk) begin
        if (o_dfi_rddata_valid_w0) begin
            rd_valid_cnt++;
            last_rd <= o_dfi_rddata_w0;
            if (rd_valid_cnt < 8)
                $display("[RDDATA] #%0d t=%0t w0=%08h", rd_valid_cnt, $time, o_dfi_rddata_w0);
        end
    end

    // ------------------------------------------------------------------
    // Reset + run
    // ------------------------------------------------------------------
    initial begin
        // Assert reset WITH a rising edge so async-set cells latch correctly
        // (Verilator zero-init never sees an edge if rst starts high)
        repeat (5) @(posedge refclk);
        rst = 1'b1;
        $display("SMOKE: reset asserted @%0t", $time);
        repeat (20) @(posedge refclk);
        rst = 1'b0;
        $display("SMOKE: reset released @%0t", $time);

        // Enable MCU clock gate: CLK_CFG(0x000B0000) = POR(0x308) | bit8(MCU_CLK_CGC_EN)
        begin : cfg
            logic [31:0] rd;
            repeat (10) @(posedge ahb_ext_clk);
            $display("SMOKE: MCU clk enabled via CLK_CFG.POR bit8 (see ddr_ctrl_csr_defs.vh)");
            dbg <= 1;
            ahb_write(32'h000B_0000, 32'h0000_0318);
            ahb_read (32'h000B_0000, rd);
            $display("SMOKE: CLK_CFG readback=%08h (expect 0318)", rd);
            dbg <= 0;
        end

        $display("SMOKE: waiting for MCU boot...");
        repeat (300000) @(posedge refclk);  // 12 ms: boot + BSS clear + init loops

        $display("=============================================");
        begin : pchisto
            int i, j, best;
            for (j = 0; j < 12 && j < pc_n; j++) begin
                best = 0;
                for (i = 1; i < pc_n; i++)
                    if (pc_vals[i] > pc_vals[best]) best = i;
                if (pc_vals[best] == 0) break;
                $display("[PCSPIN] %08h x%0d", pc_keys[best], pc_vals[best]);
                pc_vals[best] = -1;
            end
        end
        $display("pc_changes=%0d instr_req=%0d dfi_clk_edges=%0d mcu_clk_cnt=%0d",
                 pc_changes, req_cnt, dfi_clk_cnt, mcu_clk_cnt);
        $display("wr_total=%0d (dtcm=%0d csr=%0d) rd_total=%0d",
                 wr_cnt, wr_dtcm, wr_csr, rd_cnt);
        if (chphy_cnt > 1000 && rd_valid_cnt > 0)
            $display("SMOKE RESULT: FULL PASS - datapath alive, read data returned");
        else if (pc_changes > 100 && req_cnt > 100)
            $display("SMOKE RESULT: PASS - MCU fetched and executed from TCM");
        else if (pc_changes > 10)
            $display("SMOKE RESULT: WEAK - MCU alive but little activity");
        else
            $display("SMOKE RESULT: FAIL - MCU did not execute");
        $display("=============================================");
        $finish;
    end

endmodule
