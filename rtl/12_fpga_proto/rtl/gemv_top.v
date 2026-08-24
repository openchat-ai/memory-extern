// ============================================================================
// gemv_top.v — 流式 MoE 推理引擎顶层（最小可验证版本）
//
// 数据通路：权重输入 → MXFP4 解包 → bf16 MAC 阵列 → 结果
//
// 这个版本只验证核心数据通路的正确性。
// DDR4 控制器、NVMe 接口、NOC 等系统级组件在集成阶段添加。
// ============================================================================
`timescale 1ns/1ps

module gemv_top #(
    parameter NUM_LANES = 4
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- 输入：打包的 mxfp4 权重流 ----
    input  wire         wt_valid,
    input  wire [15:0]  wt_packed,       // 4×E2M1 打包码
    input  wire [7:0]   wt_scale,        // 共享 scale 指数
    input  wire [15:0]  act_vec_in,      // 激活操作数（广播）

    // ---- 输出 ----
    output reg          result_valid,
    output reg  [15:0]  result_w0,
    output reg  [15:0]  result_w1,
    output reg  [15:0]  result_w2,
    output reg  [15:0]  result_w3
);

    // ========================================================================
    // MXFP4 解包器实例化
    // ========================================================================
    wire unpack_valid;
    wire [15:0] uw0, uw1, uw2, uw3;

    mxfp4_unpacker u_unpack (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (wt_valid),
        .packed_codes(wt_packed),
        .scale_exp (wt_scale),
        .out_valid (unpack_valid),
        .w0        (uw0),
        .w1        (uw1),
        .w2        (uw2),
        .w3        (uw3)
    );

    // ========================================================================
    // MAC 阵列：NUM_LANES 条并行通道
    // ========================================================================

    // 每条 lane 的累加器
    reg [15:0] lane_acc [0:NUM_LANES-1];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_LANES; gi = gi + 1) begin : MAC
            bf16_mac_lane u_lane (
                .gclk       (clk),
                .rst_n      (rst_n),
                .lane_en    (1'b1),           // 原型阶段全部使能
                .op_valid   (unpack_valid & wt_valid),
                .weight_bf16(gi == 0 ? uw0 :
                             gi == 1 ? uw1 :
                             gi == 2 ? uw2 : uw3),
                .act_bf16   (act_vec_in),
                .accumulator(lane_acc[gi])
            );
        end
    endgenerate

    // ========================================================================
    // 结果输出（解包后的权重直接透传，用于功能验证）
    // ========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_valid <= 0;
            result_w0 <= 0; result_w1 <= 0;
            result_w2 <= 0; result_w3 <= 0;
        end else if (unpack_valid) begin
            result_valid <= 1;
            result_w0 <= uw0;
            result_w1 <= uw1;
            result_w2 <= uw2;
            result_w3 <= uw3;
        end else begin
            result_valid <= 0;
        end
    end

endmodule
