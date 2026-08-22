// WDDR PHY 通用适配版（完整）
// 不绑定特定代工厂
// 数字逻辑可移植，模拟部分通过 stub 预留接口

module wddr_phy_generic #(
    parameter NUM_DQ    = 8,
    parameter NUM_CA    = 7,
    parameter DQ_WIDTH  = NUM_DQ * 8
)(
    // 系统接口
    input  wire                     clk,            // 参考时钟
    input  wire                     rst_n,
    
    // DFI 接口
    input  wire                     dfi_clk,
    input  wire [DQ_WIDTH-1:0]     dfi_wdata,
    output wire [DQ_WIDTH-1:0]     dfi_rdata,
    input  wire                     dfi_wvalid,
    output wire                     dfi_rvalid,
    
    // DRAM 接口
    output wire [NUM_DQ-1:0]       dq_out,
    input  wire [NUM_DQ-1:0]       dq_in,
    output wire                     dq_oe,
    output wire                     ck_p,
    output wire                     ck_n,
    output wire [NUM_CA-1:0]       ca,
    output wire                     cke,
    output wire                     cs_n,
    output wire                     ras_n,
    output wire                     cas_n,
    output wire                     we_n
);

    // PLL 时钟
    wire pll_clk_0, pll_clk_90, pll_clk_180, pll_clk_270;
    wire pll_locked;
    
    // ========================================
    // PLL（需要代工厂替换）
    // ========================================
    pll_stub u_pll (
        .ref_clk(clk),
        .rst_n(rst_n),
        .clk_0(pll_clk_0),
        .clk_90(pll_clk_90),
        .clk_180(pll_clk_180),
        .clk_270(pll_clk_270),
        .locked(pll_locked)
    );
    
    // ========================================
    // 数字逻辑（可移植）
    // ========================================
    
    // TX 通路
    wddr_tx_generic #(
        .NUM_DQ(NUM_DQ)
    ) u_tx (
        .clk(pll_clk_0),
        .rst_n(rst_n & pll_locked),
        .din(dfi_wdata),
        .valid(dfi_wvalid),
        .dout(dq_out),
        .oe(dq_oe)
    );
    
    // RX 通路
    wddr_rx_generic #(
        .NUM_DQ(NUM_DQ)
    ) u_rx (
        .clk(pll_clk_0),
        .rst_n(rst_n & pll_locked),
        .din(dq_in),
        .dout(dfi_rdata),
        .valid(dfi_rvalid)
    );
    
    // ========================================
    // 模拟接口（需要代工厂替换）
    // ========================================
    
    // 时钟输出
    ck_driver_stub u_ck_driver (
        .clk_p(pll_clk_0),
        .clk_n(pll_clk_180),
        .ck_p(ck_p),
        .ck_n(ck_n)
    );
    
    // 命令地址（由控制器直接驱动）
    assign ca = 0;
    assign cke = 1;
    assign cs_n = 0;
    assign ras_n = 1;
    assign cas_n = 1;
    assign we_n = 1;

endmodule
