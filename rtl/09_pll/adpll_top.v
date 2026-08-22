// 全数字 PLL（ADPLL）— 纯数字方案
// 不需要任何模拟 IP

module adpll_top #(
    parameter TDC_WIDTH  = 8,       // TDC 位宽
    parameter DCO_WIDTH  = 6,       // DCO 控制位宽
    parameter DIV_WIDTH  = 5,       // 分频器位宽
    parameter FILT_WIDTH = 16       // 滤波器位宽
)(
    input  wire                     ref_clk,        // 参考时钟
    input  wire                     rst_n,          // 复位
    input  wire [DIV_WIDTH-1:0]     div_ratio,      // 分频比
    input  wire [DCO_WIDTH-1:0]     dco_ctrl,       // DCO 控制（外部可调）
    
    output wire                     pll_clk,        // PLL 输出
    output wire                     locked          // 锁定信号
);

    // 内部信号
    wire [TDC_WIDTH-1:0]   tdc_out;        // TDC 输出（相位差）
    wire [FILT_WIDTH-1:0]  filt_out;       // 滤波器输出
    wire                   dco_clk;        // DCO 输出
    wire                   div_clk;        // 分频后时钟
    wire                   tdc_valid;      // TDC 有效
    
    // ========================================
    // TDC（时间数字转换器）— 纯数字
    // ========================================
    tdc #(
        .WIDTH(TDC_WIDTH)
    ) u_tdc (
        .ref_clk(ref_clk),
        .fb_clk(div_clk),
        .rst_n(rst_n),
        .phase_diff(tdc_out),
        .valid(tdc_valid)
    );
    
    // ========================================
    // 数字环路滤波器 — 纯数字
    // ========================================
    digital_filter #(
        .IN_WIDTH(TDC_WIDTH),
        .OUT_WIDTH(FILT_WIDTH)
    ) u_filt (
        .clk(ref_clk),
        .rst_n(rst_n),
        .din(tdc_out),
        .valid(tdc_valid),
        .dout(filt_out)
    );
    
    // ========================================
    // DCO（数字控制振荡器）— 纯数字
    // ========================================
    dco #(
        .CTRL_WIDTH(DCO_WIDTH)
    ) u_dco (
        .ctrl(filt_out[DCO_WIDTH-1:0]),
        .rst_n(rst_n),
        .clk(dco_clk)
    );
    
    // ========================================
    // 分频器 — 纯数字
    // ========================================
    freq_divider #(
        .WIDTH(DIV_WIDTH)
    ) u_div (
        .clk(dco_clk),
        .rst_n(rst_n),
        .ratio(div_ratio),
        .divided(div_clk)
    );
    
    // ========================================
    // Lock Detector — 纯数字
    // ========================================
    lock_detector u_lock (
        .ref_clk(ref_clk),
        .fb_clk(div_clk),
        .rst_n(rst_n),
        .locked(locked)
    );
    
    // 输出
    assign pll_clk = dco_clk;

endmodule
