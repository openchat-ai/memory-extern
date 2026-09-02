// ============================================================================
// reduction_tree_norst.v — 去复位版 reduction_tree（时序实验）
//
// 配套 reduce_group_norst：stage 数据寄存器无复位，仅 valid 链复位。
// 输出级 sum_out 数据无复位（合并级只在 out_valid 时采样，安全），
// out_valid 保持复位。消除归约树内数千寄存器的 rst 扇出。
// ============================================================================

`timescale 1ns/1ps

module reduction_tree_norst #(
    parameter NUM_LANES    = 128,
    parameter ACC_WIDTH    = 32,
    parameter GROUP_LANES  = 32     // 每组 lane 数（2 的幂，整除 NUM_LANES）
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          in_valid,
    input  wire [NUM_LANES*ACC_WIDTH-1:0] acc_in,
    output reg  [ACC_WIDTH-1:0]          sum_out,
    output reg                           out_valid
);

    localparam N_GROUPS   = NUM_LANES / GROUP_LANES;
    localparam TOP_LANES  = N_GROUPS;

    wire [ACC_WIDTH-1:0] part [0:N_GROUPS-1];
    wire                 part_valid [0:N_GROUPS-1];

    genvar g;
    generate
        for (g = 0; g < N_GROUPS; g = g + 1) begin : gen_group
            reduce_group_norst #(
                .LANES(GROUP_LANES),
                .W    (ACC_WIDTH)
            ) u_group (
                .clk       (clk),
                .rst_n     (rst_n),
                .in_valid  (in_valid),
                .lane_in   (acc_in[g*GROUP_LANES*ACC_WIDTH +: GROUP_LANES*ACC_WIDTH]),
                .part      (part[g]),
                .part_valid(part_valid[g])
            );
        end

        if (TOP_LANES > 1) begin : gen_top_merge
            wire [TOP_LANES*ACC_WIDTH-1:0] top_in;
            wire                           top_valid;
            for (g = 0; g < TOP_LANES; g = g + 1) begin : gen_toplevel_in
                assign top_in[g*ACC_WIDTH +: ACC_WIDTH] = part[g];
            end
            wire [ACC_WIDTH-1:0] top_part;
            reduce_group_norst #(
                .LANES(TOP_LANES),
                .W    (ACC_WIDTH)
            ) u_top (
                .clk       (clk),
                .rst_n     (rst_n),
                .in_valid  (part_valid[0]),
                .lane_in   (top_in),
                .part      (top_part),
                .part_valid(top_valid)
            );
            always @(posedge clk) begin
                if (!rst_n) begin
                    out_valid <= 1'b0;
                end else begin
                    sum_out   <= top_part;
                    out_valid <= top_valid;
                end
            end
        end else begin : gen_top_single
            always @(posedge clk) begin
                if (!rst_n) begin
                    out_valid <= 1'b0;
                end else begin
                    sum_out   <= part[0];
                    out_valid <= part_valid[0];
                end
            end
        end
    endgenerate

endmodule