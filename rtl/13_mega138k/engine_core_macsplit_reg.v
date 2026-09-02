// ============================================================================
// engine_core_macsplit.v — MAC 阵列级拆分版（救 128-lane 布线死循环实验）
//
// 动机（B 实验 probe_dsplit 已证：仅拆归约无用）：
//   probe_dsplit 把归约顶拆成两个独立 64 收敛块（顶层仅 2 输入相加），
//   但 simd_mac_array 仍是 128-lane 单实例，其内部 x/wt 广播到 128 lane +
//   acc_bus 4096bit 全局扇出仍未变 → 仍 DEADLOOP。
//
// 本方案把『数据通路 + MAC 阵列』一起切成两个完全独立的 64-lane 收敛块：
//   x_lo(512bit,lane0..63) ─ simd_mac_array(64) → acc_lo(2048bit) → reduction_tree(64) → sum_lo
//   x_hi(512bit,lane64..127)─ simd_mac_array(64) → acc_hi(2048bit) → reduction_tree(64) → sum_hi
//   最后 sum = sum_lo + sum_hi（寄存器级相加，33bit 有符号域）
//
// 关键差异 vs B 实验（probe_dsplit 仍死）：
//   B 实验是『单个』128-lane simd_mac_array + 两个 64 归约块；
//   本方案是『两个』独立 simd_mac_array(64) 实例 + 各自 64 归约块，
//   = 与已确认收敛的 64-lane probe（MAC阵列64 + 归约64）完全同构 × 2。
//   若布通 → 布线死循环确认为「128-lane 单 MAC 阵列实例的全局广播/扇出网」，
//   实例化边界是正确解；若仍死 → 阵列规模本身触发（64×2 并行仍超收敛能力）。
//
// 数学等价：Σ(lane0..63) + Σ(lane64..127) ≡ Σ(lane0..127)
// 部分和相加在 33bit 有符号域防进位溢出，再截回 ACC_WIDTH 输出。
// ============================================================================

`timescale 1ns/1ps

module engine_core_macsplit_reg #(
    parameter NUM_LANES   = 128,
    parameter ACC_WIDTH   = 32,
    parameter HALF_LANES  = NUM_LANES/2   // 每个独立收敛块的 lane 数（必须收敛档位）
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
    // 低半块：lane[0:HALF_LANES-1] → 独立 simd_mac_array(64) → reduction_tree(64)
    // ------------------------------------------------------------------
    wire [HALF_LANES*ACC_WIDTH-1:0] acc_lo;
    wire                             done_lo;
    wire [ACC_WIDTH-1:0]             sum_lo;
    wire                             val_lo;

    simd_mac_array #(
        .NUM_LANES(HALF_LANES),
        .ACC_WIDTH(ACC_WIDTH),
        .PIPE_MUL (1),
        .PIPE_IN  (1)
    ) u_mac_lo (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .wt_valid  (wt_valid),
        .wt_data   (wt_data[0 +: HALF_LANES*4]),
        .wt_scale  (8'h40),
        .x_data    (x_data[0 +: HALF_LANES*8]),
        .x_valid   (x_valid),
        .acc_clr   (acc_clr),
        .acc_en    (1'b1),
        .acc_out   (acc_lo),
        .acc_done  (done_lo)
    );

    reduction_tree_reg #(
        .NUM_LANES   (HALF_LANES),
        .ACC_WIDTH   (ACC_WIDTH),
        .GROUP_LANES (HALF_LANES/2)     // 32：= 已知收敛的 64-lane 内部配置
    ) u_red_lo (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (done_lo),
        .acc_in    (acc_lo),
        .sum_out   (sum_lo),
        .out_valid (val_lo)
    );

    // ------------------------------------------------------------------
    // 高半块：lane[HALF_LANES:NUM_LANES-1] → 独立 simd_mac_array(64) → reduction_tree(64)
    // ------------------------------------------------------------------
    wire [HALF_LANES*ACC_WIDTH-1:0] acc_hi;
    wire                             done_hi;
    wire [ACC_WIDTH-1:0]             sum_hi;
    wire                             val_hi;

    simd_mac_array #(
        .NUM_LANES(HALF_LANES),
        .ACC_WIDTH(ACC_WIDTH),
        .PIPE_MUL (1),
        .PIPE_IN  (1)
    ) u_mac_hi (
        .clk       (clk),
        .rst_n     (rst_n),
        .en        (1'b1),
        .wt_valid  (wt_valid),
        .wt_data   (wt_data[HALF_LANES*4 +: HALF_LANES*4]),
        .wt_scale  (8'h40),
        .x_data    (x_data[HALF_LANES*8 +: HALF_LANES*8]),
        .x_valid   (x_valid),
        .acc_clr   (acc_clr),
        .acc_en    (1'b1),
        .acc_out   (acc_hi),
        .acc_done  (done_hi)
    );

    reduction_tree_reg #(
        .NUM_LANES   (HALF_LANES),
        .ACC_WIDTH   (ACC_WIDTH),
        .GROUP_LANES (HALF_LANES/2)     // 32
    ) u_red_hi (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (done_hi),
        .acc_in    (acc_hi),
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