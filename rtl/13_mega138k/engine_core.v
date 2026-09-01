// ============================================================================
// engine_core.v — 流式推理引擎核心（综合版）
//
// 数据通路：权重码流 → SIMD MAC 阵列 → 归约树 → 标量输出
// 与 tb 验证过的链路一致：simd_mac_array + reduction_tree
// ============================================================================

`timescale 1ns/1ps

module engine_core #(
    parameter NUM_LANES = 128,
    parameter ACC_WIDTH = 32
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // ---- 权重码流（外部存储控制器 / DMA 提供）----
    input  wire                       wt_valid,
    input  wire [NUM_LANES*4-1:0]     wt_data,
    // ---- 激活向量（RISC-V / DMA 配置）----
    input  wire [NUM_LANES*8-1:0]     x_data,
    input  wire                       x_valid,
    // ---- 控制 ----
    input  wire                       acc_clr,

    // ---- 结果 ----
    output wire [ACC_WIDTH-1:0]       sum_out,
    output wire                       sum_valid,
    output wire                       busy
);

    // ------------------------------------------------------------------
    // SIMD MAC 阵列：每 lane 独立累加器
    // PIPE_MUL=1：打断关键路径（乘积锁存一拍 + 累加一拍），撑到 200MHz
    // ------------------------------------------------------------------
    wire [NUM_LANES*ACC_WIDTH-1:0] acc_bus;
    wire                           acc_done;

    simd_mac_array #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(ACC_WIDTH),
        .PIPE_MUL (1)             // 超频/布线：流水打断关键路径
    ) u_mac (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .wt_valid  (wt_valid),
        .wt_data   (wt_data),
        .wt_scale  (8'h40),
        .x_data    (x_data),
        .x_valid   (x_valid),
        .acc_clr   (acc_clr),
        .acc_en    (1'b1),
        .acc_out   (acc_bus),
        .acc_done  (acc_done)
    );

    // ------------------------------------------------------------------
    // 归约树：128 → 1，log2(128)=7 级流水
    // ------------------------------------------------------------------
    reduction_tree #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_reduce (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (acc_done),
        .acc_in    (acc_bus),
        .sum_out   (sum_out),
        .out_valid (sum_valid)
    );

    assign busy = wt_valid;

endmodule
