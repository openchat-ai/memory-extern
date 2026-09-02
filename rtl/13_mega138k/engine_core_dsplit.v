// ============================================================================
// engine_core_dsplit.v — 数据通路级拆分版（救 128-lane 布线死循环实验）
//
// 动机（A 实验已证：仅改归约分组无用）：
//   128-lane 死循环 = 全局 4096bit 归约扇入（stage0 收全场）超布线引擎收敛能力，
//   并非归约树顶层分组位数问题。
//
// 本方案把『数据通路』在归约入口就切成两个完全独立的 64-lane 收敛块：
//   acc_bus(4096bit, lane 0..127) ─┬─ acc_lo(2048bit, lane 0..63)
//                                  │            └ reduction_tree(64, GROUP_LANES=32) → sum_lo
//                                  └─ acc_hi(2048bit, lane 64..127)
//                                               └ reduction_tree(64, GROUP_LANES=32) → sum_hi
//   最后 sum = sum_lo + sum_hi（寄存器级相加）
//
// 关键差异 vs A 实验（GROUP_LANES=64 顶层 TOP_LANES=2 仍死）：
//   A 实验是『单个』宽归约树内含 64-lane stage 数组；
//   本方案是『两个』独立的 reduction_tree(NUM_LANES=64,GROUP_LANES=32) 实例，
//   每个的扇入 root 只有 2048bit = 与已确认收敛的 64-lane probe 完全同构。
//   顶层只剩一个 2 输入部分和相加（2×32bit，扇入极小，布线性极佳）。
//
// 数学等价：加法结合律 Σ(lane0..63) + Σ(lane64..127) ≡ Σ(lane0..127)
// 部分和相加在 33bit 有符号域防进位溢出，再截回 ACC_WIDTH 输出（与原 128 树行为一致）。
// ============================================================================

`timescale 1ns/1ps

module engine_core_dsplit #(
    parameter NUM_LANES   = 128,
    parameter ACC_WIDTH   = 32,
    parameter HALF_LANES  = NUM_LANES/2   // 每个独立归约块的 lane 数（必须收敛档位）
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // ---- 权重码流 ----
    input  wire                         wt_valid,
    input  wire [NUM_LANES*4-1:0]       wt_data,
    // ---- 激活向量 ----
    input  wire [NUM_LANES*8-1:0]       x_data,
    input  wire                         x_valid,
    // ---- 控制 ----
    input  wire                         acc_clr,

    // ---- 结果 ----
    output wire [ACC_WIDTH-1:0]         sum_out,
    output wire                         sum_valid,
    output wire                         busy
);

    // ------------------------------------------------------------------
    // SIMD MAC 阵列：128 lane，每 lane 独立累加器
    // ------------------------------------------------------------------
    wire [NUM_LANES*ACC_WIDTH-1:0] acc_bus;
    wire                            acc_done;

    simd_mac_array #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(ACC_WIDTH),
        .PIPE_MUL (1),
        .PIPE_IN  (1)
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
    // 数据通路级拆分：acc_bus 按 lane 切成两半，各自独立归约
    // hal_width = HALF_LANES * ACC_WIDTH = 2048bit（hal_width 位序 [0..1999]?
    // 实际 [0..2047]）
    // ------------------------------------------------------------------
    localparam HALF = HALF_LANES * ACC_WIDTH;   // 半个归约块位宽（2048bit）

    wire [ACC_WIDTH-1:0] sum_lo;
    wire [ACC_WIDTH-1:0] sum_hi;
    wire                 val_lo;
    wire                 val_hi;

    // lane[0:HALF_LANES-1] → acc_lo；lane[HALF_LANES:NUM_LANES-1] → acc_hi
    // Gowin 要求部分选方向与数组声明一致（acc_bus 为降序 [..:0]）→ 用 "-:" 降序切片
    reduction_tree #(
        .NUM_LANES   (HALF_LANES),      // 64
        .ACC_WIDTH   (ACC_WIDTH),
        .GROUP_LANES (HALF_LANES/2)     // 32：= 已知收敛的 64-lane 内部配置
    ) u_red_lo (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (acc_done),
        .acc_in    (acc_bus[HALF-1 -: HALF]),       // bit [HALF-1 : 0]（lane0..63）
        .sum_out   (sum_lo),
        .out_valid (val_lo)
    );

    reduction_tree #(
        .NUM_LANES   (HALF_LANES),      // 64
        .ACC_WIDTH   (ACC_WIDTH),
        .GROUP_LANES (HALF_LANES/2)     // 32
    ) u_red_hi (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (acc_done),
        .acc_in    (acc_bus[NUM_LANES*ACC_WIDTH-1 -: HALF]),  // bit [4095 : HALF]（lane64..127）
        .sum_out   (sum_hi),
        .out_valid (val_hi)
    );

    // ------------------------------------------------------------------
    // 合并级：sum_lo + sum_hi（33bit 有符号域），打拍输出
    // 两路 out_valid 流水深度相同，同拍到达 → 取一路做 valid
    // ------------------------------------------------------------------
    wire signed [ACC_WIDTH:0] merged =
        {{1{sum_lo[ACC_WIDTH-1]}}, sum_lo} +
        {{1{sum_hi[ACC_WIDTH-1]}}, sum_hi};

    reg  signed [ACC_WIDTH-1:0] sum_r;
    reg                          sum_valid_r;
    always @(posedge clk) begin
        if (!rst_n) begin
            sum_r       <= {ACC_WIDTH{1'b0}};
            sum_valid_r <= 1'b0;
        end else begin
            sum_r       <= merged[ACC_WIDTH-1:0];
            sum_valid_r <= val_lo;      // 两路同拍，取 lo
        end
    end

    assign sum_out   = sum_r;
    assign sum_valid = sum_valid_r;
    assign busy      = wt_valid;

endmodule