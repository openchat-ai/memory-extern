// ============================================================================
// reduction_tree.v — 把 NUM_LANES 个部分和归约成单个输出
//
// log2(N) 级加法树：
//   128 → 64 → 32 → 16 → 8 → 4 → 2 → 1
//   共 7 级，每级延迟 1 拍（流水化）
// ============================================================================

`timescale 1ns/1ps

module reduction_tree #(
    parameter NUM_LANES = 128,
    parameter ACC_WIDTH = 32
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          in_valid,
    input  wire [NUM_LANES*ACC_WIDTH-1:0] acc_in,
    output reg  [ACC_WIDTH-1:0]          sum_out,
    output reg                           out_valid
);

    // 流水线深度 = ceil(log2(NUM_LANES))
    localparam STAGES = $clog2(NUM_LANES);   // 128 → 7

    // 中间寄存器阵列：每级数量减半
    reg signed [ACC_WIDTH-1:0] stage [0:STAGES-1][0:NUM_LANES/2-1];
    reg valid_pipe [0:STAGES];

    integer s, k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < STAGES; s = s + 1)
                for (k = 0; k < NUM_LANES/2; k = k + 1)
                    stage[s][k] <= {ACC_WIDTH{1'b0}};
            for (s = 0; s <= STAGES; s = s + 1)
                valid_pipe[s] <= 1'b0;
            sum_out   <= {ACC_WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else begin
            // 第 0 级：相邻两个累加器相加
            for (k = 0; k < NUM_LANES/2; k = k + 1) begin
                if (in_valid)
                    stage[0][k] <= $signed(acc_in[(2*k)*ACC_WIDTH +: ACC_WIDTH])
                                 + $signed(acc_in[(2*k+1)*ACC_WIDTH +: ACC_WIDTH]);
            end

            // 后续各级：继续两两归约
            for (s = 1; s < STAGES; s = s + 1) begin
                for (k = 0; k < NUM_LANES/(2*(s+1)); k = k + 1) begin
                    stage[s][k] <= $signed(stage[s-1][2*k])
                                 + $signed(stage[s-1][2*k+1]);
                end
            end

            // 有效信号沿流水线传播
            valid_pipe[0] <= in_valid;
            for (s = 1; s <= STAGES; s = s + 1)
                valid_pipe[s] <= valid_pipe[s-1];

            // 最终输出
            sum_out   <= stage[STAGES-1][0];
            out_valid <= valid_pipe[STAGES-1];
        end
    end

endmodule
