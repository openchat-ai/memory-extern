// 代工厂接口 Stub 模块
// 这些模块需要根据具体代工厂替换

// ========================================
// PLL Stub
// ========================================
// 需要代工厂提供：
// - 输入：参考时钟
// - 输出：多相时钟（0°, 90°, 180°, 270°）
// - 参数：频率、抖动、功耗
module pll_stub (
    input  wire     ref_clk,
    input  wire     rst_n,
    output wire     clk_0,
    output wire     clk_90,
    output wire     clk_180,
    output wire     clk_270,
    output wire     locked
);
    // 简化实现：直接输出参考时钟
    // 实际需要替换为代工厂 PLL
    assign clk_0 = ref_clk;
    assign clk_90 = ref_clk;      // 需要 90° 相移
    assign clk_180 = ~ref_clk;    // 需要 180° 相移
    assign clk_270 = ~ref_clk;    // 需要 270° 相移
    assign locked = 1'b1;
endmodule

// ========================================
// 时钟驱动器 Stub
// ========================================
// 需要代工厂提供：
// - 差分时钟输出
// - 阻抗匹配
// - 驱动强度
module ck_driver_stub (
    input  wire     clk_p,
    input  wire     clk_n,
    output wire     ck_p,
    output wire     ck_n
);
    assign ck_p = clk_p;
    assign ck_n = clk_n;
endmodule

// ========================================
// DQ 驱动器 Stub
// ========================================
// 需要代工厂提供：
// - 单端/差分输出
// - 可编程驱动强度
// - 预加重
module dq_driver_stub (
    input  wire [7:0] din,
    input  wire       oe,
    output wire [7:0] dout
);
    assign dout = oe ? din : 8'hzz;
endmodule

// ========================================
// DQ 接收器 Stub
// ========================================
// 需要代工厂提供：
// - 差分接收
// - 可编程阈值
// - 偏置校准
module dq_receiver_stub (
    input  wire [7:0] din,
    output wire [7:0] dout
);
    assign dout = din;
endmodule

// ========================================
// CA 驱动器 Stub
// ========================================
module ca_driver_stub (
    input  wire [6:0] din,
    output wire [6:0] dout
);
    assign dout = din;
endmodule
