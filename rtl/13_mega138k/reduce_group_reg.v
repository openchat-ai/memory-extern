// ============================================================================
// reduce_group_reg.v — 局部归约组：把 GROUP_LANES 个输入归约为 1 个部分和
//
// 与 reduce_group.v 逻辑、端口、时序完全一致，唯一差异：
//   各级加法树寄存器用 generate 块显式命名（gen_stage[s].gen_slot[k].r），
//   避免综合器把二维数组 stage 推断成 RAM 而将寄存器物理集中。
//   目标：每个加法器 + 其输出寄存器就近散布，符合"小集合就地布局"。
//
// 结构：log2(LANES) 级流水加法树，part/part_valid 为末级寄存器输出的
//       组合连线，总延迟 == 原 flat 树的一致对齐。
// ============================================================================

`timescale 1ns/1ps

module reduce_group_reg #(
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

        reg valid_pipe [0:STAGES];

        integer p;
        always @(posedge clk) begin
            if (!rst_n) begin
                for (p = 0; p <= STAGES; p = p + 1)
                    valid_pipe[p] <= 1'b0;
            end else begin
                valid_pipe[0] <= in_valid;
                for (p = 1; p <= STAGES; p = p + 1)
                    valid_pipe[p] <= valid_pipe[p-1];
            end
        end

        genvar s, k;
        for (s = 0; s < STAGES; s = s + 1) begin : gen_stage
            // 第 s 级有 LANES/(2^(s+1)) 个累加槽（逐级减半）
            for (k = 0; k < LANES/(1 << (s+1)); k = k + 1) begin : gen_slot
                reg [W-1:0] r;
                always @(posedge clk) begin
                    if (!rst_n)
                        r <= {W{1'b0}};
                    else if (s == 0) begin
                        if (in_valid)
                            r <= $signed(lane_in[(2*k)*W +: W])
                               + $signed(lane_in[((2*k)+1)*W +: W]);
                    end else begin
                        r <= $signed(gen_stage[s-1].gen_slot[2*k].r)
                           + $signed(gen_stage[s-1].gen_slot[2*k+1].r);
                    end
                end
            end
        end

        assign part       = gen_stage[STAGES-1].gen_slot[0].r;
        assign part_valid = valid_pipe[STAGES-1];
    end else begin : gen_single
        assign part       = lane_in;
        assign part_valid = in_valid;
    end

endmodule