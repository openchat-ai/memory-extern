// PLL 顶层模块 — 14nm 自主设计
// 数字部分可移植，模拟部分需要14nm工艺

module pll_top #(
    parameter DIV_WIDTH = 5,        // 分频器位宽
    parameter DIV_RATIO = 20        // 默认分频比
)(
    input  wire                 ref_clk,        // 参考时钟
    input  wire                 rst_n,          // 复位
    input  wire [DIV_WIDTH-1:0] div_ratio,      // 分频比设置
    
    output wire                 pll_clk,        // PLL 输出时钟
    output wire                 locked          // 锁定信号
);

    // 内部信号
    wire                pfd_up, pfd_down;       // PFD 输出
    wire                cp_out;                 // 电荷泵输出
    wire                vco_clk;                // VCO 输出
    wire                vco_divided;            // 分频后时钟
    wire [DIV_WIDTH-1:0] div_count;             // 分频计数器
    
    // ========================================
    // PFD（鉴频鉴相器）— 数字，可移植
    // ========================================
    pfd u_pfd (
        .ref_clk(ref_clk),
        .fb_clk(vco_divided),
        .rst_n(rst_n),
        .up(pfd_up),
        .down(pfd_down)
    );
    
    // ========================================
    // Charge Pump（电荷泵）— 模拟，需要14nm
    // ========================================
    // TODO: 替换为14nm Charge Pump
    charge_pump_stub u_cp (
        .up(pfd_up),
        .down(pfd_down),
        .out(cp_out)
    );
    
    // ========================================
    // Loop Filter（环路滤波器）— 被动元件
    // ========================================
    // TODO: 替换为14nm电阻电容
    loop_filter_stub u_lf (
        .in(cp_out),
        .vctrl(vctrl)
    );
    
    // ========================================
    // VCO（压控振荡器）— 模拟，最难
    // ========================================
    // TODO: 替换为14nm VCO
    wire vctrl;
    vco_stub u_vco (
        .vctrl(vctrl),
        .clk(vco_clk),
        .rst_n(rst_n)
    );
    
    // ========================================
    // 分频器 — 数字，可移植
    // ========================================
    freq_divider #(
        .WIDTH(DIV_WIDTH)
    ) u_div (
        .clk(vco_clk),
        .rst_n(rst_n),
        .ratio(div_ratio),
        .divided(vco_divided)
    );
    
    // ========================================
    // Lock Detector — 数字，可移植
    // ========================================
    lock_detector u_lock (
        .ref_clk(ref_clk),
        .fb_clk(vco_divided),
        .rst_n(rst_n),
        .locked(locked)
    );
    
    // 输出
    assign pll_clk = vco_clk;

endmodule
