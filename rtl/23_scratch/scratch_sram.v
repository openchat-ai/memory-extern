`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// scratch_sram.v — 96KB 行为级 scratch 宏 (M8)
//
// 定位 (冻结基线 §7): SRAM 域里 96KB scratch, 三个占位主共用:
//     router 排序 / softmax 分块 / ROPE·熵查表。
// 本文只出"域 + 读写作弊收口", 占位引擎(router_topk)另有文件。
//
// 语义:
//   - 读口组合直读 (a_data = mem[a_addr], 无寄存器), 与行为级池/窗同家风;
//   - 写口号字节使能 b_be[7:0] (1=可写该字节), 掩码写字, 未使能字节不动;
//   - 容量按 BYTES 参数化 (实配 96KB=98304B; DW=64 → 12288 字);
//   - 端到端字节视图对账: 槽位号 slot=k&(DW/16-1), 字内偏移 k 的 16bit 槽 = (k*16)%DW。
// 纪律 (M7/M6 沉淀): 观测口位宽容终值; 数据按字节掩码语义落地, 不整字吹。
//────────────────────────────────────────────────────────────────────────────
module scratch_sram #(
    parameter BYTES = 96 * 1024,
    parameter DW    = 64
)(
    input  wire         clk,
    input  wire         rst_n,

    // ---- 读口 ----
    input  wire [AW-1:0] a_addr,
    output wire [DW-1:0] a_data,

    // ---- 写口 ----
    input  wire [AW-1:0] b_addr,
    input  wire          b_wr,
    input  wire [7:0]    b_be,
    input  wire [DW-1:0] b_data
);

    localparam DEPTH = BYTES / (DW / 8);
    localparam AW    = $clog2(DEPTH);

    reg [DW-1:0] mem [0:DEPTH-1];

    assign a_data = mem[a_addr];

    integer i;
    always @(posedge clk) begin
        if (b_wr) begin
            reg [DW-1:0] w;
            w = mem[b_addr];
            for (i = 0; i < 8; i = i + 1) begin
                if (b_be[i]) w[i*8 +: 8] = b_data[i*8 +: 8];
            end
            mem[b_addr] <= w;
        end
    end

endmodule
`default_nettype wire