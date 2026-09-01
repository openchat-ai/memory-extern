// ============================================================================
// reduce_group.v — 局部归约组：把 GROUP_LANES 个输入归约为 1 个部分和
//
// 用于把 128-lane 归约树切分成若干局部组，缩短全局布线跨度：
//     总体 GoW 布线压力由 4096bit 全局扇入 → 每组仅 1024bit 局部扇入
//
// 结构：log2(LANES) 级流水加法树，part/part_valid 为末级寄存器输出的
//       组合连线（不再额外打拍），保证总延迟 == 原 flat 树的一致对齐。
// ============================================================================

`timescale 1ns/1ps

module reduce_group #(
    parameter LANES = 32,      // 本组 lane 数（2 的幂）
    parameter W      = 32      // 数据位宽
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire                    in_valid,
    input  wire [LANES*W-1:0]      lane_in,
    output wire [W-1:0]            part,        // 部分和（末级寄存器直接连出）
    output wire                    part_valid
);

    if (LANES > 1) begin : gen_multi
        localparam STAGES = $clog2(LANES);

        reg [W-1:0] stage [0:STAGES-1][0:LANES/2-1];
        reg valid_pipe [0:STAGES];

        integer s, k;
        always @(posedge clk) begin
            if (!rst_n) begin
                for (s = 0; s < STAGES; s = s + 1)
                    for (k = 0; k < LANES/2; k = k + 1)
                        stage[s][k] <= {W{1'b0}};
                for (s = 0; s <= STAGES; s = s + 1)
                    valid_pipe[s] <= 1'b0;
            end else begin
                for (k = 0; k < LANES/2; k = k + 1) begin
                    if (in_valid)
                        stage[0][k] <= $signed(lane_in[(2*k)*W +: W])
                                     + $signed(lane_in[(2*k+1)*W +: W]);
                end

                for (s = 1; s < STAGES; s = s + 1) begin
                    for (k = 0; k < LANES/(2*(s+1)); k = k + 1) begin
                        stage[s][k] <= $signed(stage[s-1][2*k])
                                     + $signed(stage[s-1][2*k+1]);
                    end
                end
                valid_pipe[0] <= in_valid;
                for (s = 1; s <= STAGES; s = s + 1)
                    valid_pipe[s] <= valid_pipe[s-1];
            end
        end

        assign part       = stage[STAGES-1][0];
        assign part_valid = valid_pipe[STAGES-1];
    end else begin : gen_single
        assign part       = lane_in;
        assign part_valid = in_valid;
    end

endmodule