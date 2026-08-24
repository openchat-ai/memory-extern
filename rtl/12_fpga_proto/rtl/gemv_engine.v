// ============================================================================
// gemv_engine.v — 流式 GEMV 推理引擎（最小可综合版本）
//
// 数据流：
//   NVMe/存储 → 预取 FIFO → 解包器 → MAC 消费
//
// 本模块验证核心数据通路：预取不阻塞计算，计算不阻塞预取。
// ============================================================================

`timescale 1ns/1ps

module gemv_engine #(
    parameter NUM_LANES   = 8,     // MAC 通道数（原型用小值）
    parameter FIFO_DEPTH  = 64,    // 预取 FIFO 深度
    parameter ADDR_WIDTH  = 32     // 权重地址位宽
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- 权重输入流（来自存储控制器）----
    input  wire                    wt_valid,       // 权重数据有效
    input  wire [31:0]             wt_data,        // 打包权重（4×E2M1）
    input  wire [7:0]              wt_scale,       // 共享 scale
    output wire                    wt_ready,       // 可以接收更多数据

    // ---- 计算控制 ----
    input  wire                    start,          // 启动一次推理
    input  wire [31:0]            total_weights,   // 本轮需要处理的权重总数
    output reg                     busy,           // 引擎忙

    // ---- 结果输出 ----
    output reg  [31:0]             result,         // 累加结果（简化：标量输出）
    output reg                     result_valid,   // 结果有效脉冲
    output reg  [31:0]             tokens_done     // 已完成 token 计数
);

    // ========================================================================
    // 状态机
    // ========================================================================
    localparam S_IDLE      = 2'd0;
    localparam S_LOAD      = 2'd1;   // 从输入流加载权重
    localparam S_COMPUTE   = 2'd2;   // MAC 消费中
    localparam S_DONE      = 2'd3;   // 单 token 完成

    reg [1:0]  state;
    reg [31:0] weight_cnt;         // 已消费权重计数
    reg [31:0] acc;                // 累加器（简化为定点）

    // ========================================================================
    // 权重解包：mxfp4 E2M1 码 → 有符号值（简化定点，省略 scale 还原）
    // 输入 32bit = 8 个 4bit 码，每个码查表得 [-6, 6] 范围的有符号值
    // ========================================================================

    function signed [7:0] e2m1_decode;
        input [3:0] code;
        case (code[2:0])
            3'b000: e2m1_decode = 0;
            3'b001: e2m1_decode = 2;     // 0.5 × 4 = 2（放大4倍便于整数运算）
            3'b010: e2m1_decode = 4;     // 1.0
            3'b011: e2m1_decode = 6;     // 1.5
            3'b100: e2m1_decode = 8;     // 2.0
            3'b101: e2m1_decode = 12;    // 3.0
            3'b110: e2m1_decode = 16;    // 4.0
            3'b111: e2m1_decode = 24;    // 6.0
            default: e2m1_decode = 0;
        endcase
        if (code[3]) e2m1_decode = -e2m1_decode;
    endfunction

    // 每周期从 32bit 中解出 8 个 int4 权重并累加乘积
    // 简化模型：acc += Σ(w_i × x_i)，x 向量由外部提供
    // 原型阶段用一个简化的点积代替完整矩阵运算

    // ========================================================================
    // 主处理逻辑
    // ========================================================================

    wire load_en = wt_valid && (state == S_LOAD || state == S_COMPUTE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            weight_cnt  <= 32'd0;
            acc         <= 32'd0;
            result      <= 32'd0;
            result_valid<= 1'b0;
            tokens_done <= 32'd0;
        end else begin
            result_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        state      <= S_LOAD;
                        busy       <= 1'b1;
                        weight_cnt <= 32'd0;
                        acc        <= 32'd0;
                    end
                end

                S_LOAD: begin
                    // 从输入流接收打包权重并累加
                    if (load_en) begin
                        // 解包 8 个 int4 并做点积累加（简化模型）
                        acc <= acc + dot8(wt_data);
                        weight_cnt <= weight_cnt + 8;
                        if (weight_cnt + 8 >= total_weights) begin
                            state <= S_DONE;
                            busy  <= 1'b0;
                        end
                    end
                end

                S_DONE: begin
                    result       <= acc;
                    result_valid <= 1'b1;
                    tokens_done  <= tokens_done + 1;
                    state        <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // 简化点积：把 32bit 按 8×4bit 解包后求和（原型验证用）
    function [31:0] dot8;
        input [31:0] packed_w;
        reg [31:0] sum;
        begin
            sum = 0;
            sum = sum + e2m1_decode(packed_w[3:0]);
            sum = sum + e2m1_decode(packed_w[7:4]);
            sum = sum + e2m1_decode(packed_w[11:8]);
            sum = sum + e2m1_decode(packed_w[15:12]);
            sum = sum + e2m1_decode(packed_w[19:16]);
            sum = sum + e2m1_decode(packed_w[23:20]);
            sum = sum + e2m1_decode(packed_w[27:24]);
            sum = sum + e2m1_decode(packed_w[31:28]);
            dot8 = sum;
        end
    endfunction

endmodule
