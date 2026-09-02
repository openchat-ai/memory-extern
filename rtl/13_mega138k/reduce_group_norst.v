// ============================================================================
// reduce_group_norst.v — 去复位版 reduce_group（时序实验）
//
// 动机：full_macsplit 时序显示复位路径成为关键路径
//   （rst_sync→RAMREG_D、RAMREG_1→RAMREG_2 RESET），综合器把异步复位
//   塞进数据路径，rst 高扇出拖累 Fmax。
//   stage 数据寄存器功能上不需要复位：valid 链对齐保证输出只在
//   out_valid 拉高时被采样，复位期间 out_valid=0 输出无效。
//   故去掉 stage 数据寄存器复位（保留 valid_pipe 复位），
//   消除数千个 stage 寄存器的 rst 扇出。
// ============================================================================

`timescale 1ns/1ps

module reduce_group_norst #(
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