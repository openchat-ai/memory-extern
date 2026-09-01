// ============================================================================
// reduction_tree.v — 把 NUM_LANES 个部分和归约成单个输出（分层结构）
//
// 布线优化版：把 4096bit 全局 acc_bus 扇入 64 个 stage0 加法器的长跨度结构
// 拆成『局部组 + 顶层合并』，缩短布线器需要收敛的全局网：
//   128 = 4 组 × 32 lane（各组内 32→1 局部归约）→ 4 个部分和 → 顶层 4→1
//
// 逻辑不变、端口不变、总延迟不变：
//   组内 log2(32)=5 级 + 顶层 log2(4)=2 级 + 输出打拍 1 级 = 8 拍
//   （与原 flat 树 7 级 + 输出 1 拍 完全一致，tb 对齐不需改动）
// ============================================================================

`timescale 1ns/1ps

module reduction_tree #(
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

    // 组/顶层级数
    localparam N_GROUPS   = NUM_LANES / GROUP_LANES;         // 4
    localparam TOP_LANES  = N_GROUPS;                        // 合并组输入数

    // ---- 各局部组的部分和（整组同拍到达）----
    wire [ACC_WIDTH-1:0] part [0:N_GROUPS-1];
    wire                 part_valid [0:N_GROUPS-1];

    genvar g;
    generate
        for (g = 0; g < N_GROUPS; g = g + 1) begin : gen_group
            reduce_group #(
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

        // 顶层：合并各组的 part（注意所有组 lane 号需连续，part 位序按组序）
        if (TOP_LANES > 1) begin : gen_top_merge
            wire [TOP_LANES*ACC_WIDTH-1:0] top_in;
            wire                           top_valid;
            for (g = 0; g < TOP_LANES; g = g + 1) begin : gen_toplevel_in
                assign top_in[g*ACC_WIDTH +: ACC_WIDTH] = part[g];
            end
            wire [ACC_WIDTH-1:0] top_part;
            reduce_group #(
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
                    sum_out   <= {ACC_WIDTH{1'b0}};
                    out_valid <= 1'b0;
                end else begin
                    sum_out   <= top_part;
                    out_valid <= top_valid;
                end
            end
        end else begin : gen_top_single
            always @(posedge clk) begin
                if (!rst_n) begin
                    sum_out   <= {ACC_WIDTH{1'b0}};
                    out_valid <= 1'b0;
                end else begin
                    sum_out   <= part[0];
                    out_valid <= part_valid[0];
                end
            end
        end
    endgenerate

endmodule