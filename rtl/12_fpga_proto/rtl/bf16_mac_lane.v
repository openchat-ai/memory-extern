// ============================================================================
// bf16_mac_lane.v — 单条 MAC 通道（bf16 乘累加，带门控）
//
// 每个周期：acc += weight × activation
// 权重来自解包器输出，激活从寄存器堆广播
// 门控：gclk 停振时不消耗动态功耗
// ============================================================================
`timescale 1ns/1ps

module bf16_mac_lane (
    input  wire        gclk,          // 门控后本地时钟
    input  wire        rst_n,
    input  wire        lane_en,       // 本 lane 使能
    input  wire        op_valid,      // 操作数有效
    input  wire [15:0] weight_bf16,   // 权重操作数
    input  wire [15:0] act_bf16,      // 激活操作数
    output reg  [15:0] accumulator    // bf16 累加器
);

    // bf16 乘法：取 bf16 高位做近似乘法（FPGA 原型精度足够）
    // 完整实现用 DSP48 或类似硬核
    function [15:0] bf16_mul;
        input [15:0] a, b;
        reg [31:0] full;  // fp32 中间结果截断为 bf16
        begin
            // 简化：符号×符号 + 指数相加 -127 + 尾数近似乘法
            full[31]    = a[15] ^ b[15];
            full[30:23] = a[14:7] + b[14:7] - 127;
            full[22:0]  = (a[6:0] * b[6:0]) >> 7;  // 近似尾数
            bf16_mul = {full[31], full[30:23], full[22:16]};
        end
    endfunction

    function [15:0] bf16_add;
        input [15:0] a, b;
        // 简化：fp32 加法后截断
        reg [31:0] ea, eb, es;
        begin
            ea = {a, 7'b0};
            eb = {b, 7'b0};
            if (a[14:7] > b[14:7])
                es = {a[15], a[14:7], ((ea[22:0] >>> (a[14:7]-b[14:7])) + eb[22:0])};
            else
                es = {b[15], b[14:7], ((eb[22:0] >>> (b[14:7]-a[14:7])) + ea[22:0])};
            bf16_add = {es[31], es[30:23], es[22:13]};
        end
    endfunction

    wire [15:0] product = bf16_mul(weight_bf16, act_bf16);
    wire [15:0] sum     = bf16_add(accumulator, product);

    always @(posedge gclk or negedge lane_en) begin
        if (!lane_en) accumulator <= 16'b0;
        else          accumulator <= sum;
    end

endmodule
