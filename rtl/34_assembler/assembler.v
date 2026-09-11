`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// assembler.v — M18 专家装配件: router top-T 选出 → 按 (层,实体号) 从层切片
// 顺序拉实体权重块 EW 词 → 吐给 GEMM 段 (P2 装配流)
//
// 契约 (board-1g-k3-frozen.md §9 专家库侧索引/装配):
//   先选后抽: router 每层吐出 top-T 专家号 → 本件逐拍收进 idx_slot[];
//   收该层 TOP 个 → 依序逐实体取 EW 词 (切片 LUT: 层内实体块连续排布,
//   index = lay*EX*EW + expert*EW + w), out_valid/out_take 手拉手吐流;
//   层内严格保序 (选出序=专家抽取序) → layer_done(barrier) → 下一层 TAKE;
//   NL 层完工 → token_done → round++ (P1 搬运给切片数据, 此处切片=LUT 预灌).
//   背压: 装配侧 (GEMM 段) 连拍吃不下 → 停拍记 stall 不丢不序;
//         上游 (router) 断灌 in_valid 低 → 本件等, 不丢不序;
//   slice 双口: TB 用 wr_en/wr_addr/wr_data 预灌 (替换为 P1 装载即板侧装填).
//────────────────────────────────────────────────────────────────────────────
module assembler #(
    parameter EX   = 32,     // 候选专家/层 (演练口径; P2=层实体库全量)
    parameter TOP  = 8,      // 每层选出数 (P2 冻结 top-16)
    parameter EW   = 8,      // 每实体权重词数 (FAST 假权重; P2=实体块实际规模)
    parameter NL   = 3,      // 座席层/会话
    parameter SW   = 16,     // 权重词位宽
    parameter RNDW = 6       // round 计数位宽
)(
    input  wire       clk, rst_n, go,
    // ── 入口: router 逐拍吐 top-T (本层一批, TAKE 期手拉手) ──
    input  wire       in_valid,
    input  wire [$clog2(EX)-1:0]  in_idx,
    output wire       in_take,
    // ── 出口: 实体权重词顺序流 (到 GEMM 段) ──
    output reg         out_valid,
    output reg [SW-1:0]        out_data,
    output reg [$clog2(EX)-1:0] out_expert,
    input  wire       out_take,
    // ── 切片双口 (P1 由装载器写; FAST 由 TB 预灌) ──
    input  wire       wr_en,
    input  wire [$clog2(NL*EX*EW)-1:0] wr_addr,
    input  wire [SW-1:0]                 wr_data,
    // ── 状态/统计 ──
    output wire       layer_done, token_done,
    output reg  [$clog2(NL)-1:0] lay_idx = 0,
    output reg  [RNDW-1:0]       round   = 0,
    output reg  [31:0]           stalls  = 0,
    output reg  [31:0]           words   = 0
);
    localparam AW  = $clog2(NL*EX*EW);   // 切片寻址宽
    localparam XW  = $clog2(EX);
    localparam TW  = $clog2(TOP);
    localparam WLW = $clog2(EW);

    localparam S_IDLE = 2'd0, S_TAKE = 2'd1, S_EMIT = 2'd2;
    reg [1:0] st = S_IDLE;
    reg [TW-1:0]   k;                    // TAKE 已收条数
    reg [TW-1:0]   ep;                   // EMIT 当前实体 (0..TOP-1)
    reg [WLW-1:0]  wp;                   // EMIT 实体内词序
    reg [AW-1:0]   caddr;                // 正在吐的切片地址
    reg [XW-1:0]   idx_slot [0:TOP-1];   // 本层选出实体号 (层缓存)
    reg            ld_p = 0, td_p = 0;   // 层/会话完工脉冲
    reg [SW-1:0]   slice_mem [0:NL*EX*EW-1];

    // 实体块首址: lay*EX*EW + expert*EW
    function integer bebase(input integer e);
        bebase = lay_idx*(EX*EW) + idx_slot[e]*EW;
    endfunction

    wire busy = (st != S_IDLE);
    assign in_take   = (st == S_TAKE) && in_valid;
    assign layer_done = ld_p;
    assign token_done = td_p;

    always @(*) out_expert = idx_slot[ep];
    always @(*) out_data   = slice_mem[caddr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; k <= 0; ep <= 0; wp <= 0;
            caddr <= 0; lay_idx <= 0; round <= 0;
            out_valid <= 0; ld_p <= 0; td_p <= 0;
            stalls <= 0; words <= 0;
        end else begin
            case (st)
                S_IDLE: begin
                    td_p <= 0;
                    if (go) begin st <= S_TAKE; k <= 0; end
                end
                S_TAKE: begin
                    ld_p <= 0;
                    if (in_take) begin
                        idx_slot[k] <= in_idx;
                        if (k == TOP-1) begin
                            st <= S_EMIT; ep <= 0; wp <= 0;
                            caddr <= bebase(0);
                            out_valid <= 1;
                        end else k <= k + 1;
                    end
                end
                S_EMIT: begin
                    if (out_valid && out_take) begin
                        words <= words + 1;
                        if (wp == EW-1) begin
                            if (ep == TOP-1) begin      // 本层实体全吐完
                                out_valid <= 0;
                                if (lay_idx == NL-1) begin  // 会话完工
                                    td_p <= 1; round <= round + 1;
                                    st <= S_IDLE;
                                end else begin
                                    ld_p <= 1; lay_idx <= lay_idx + 1;
                                    st <= S_TAKE; k <= 0;
                                end
                            end else begin               // 下一实体 (选中序, 非按号连续)
                                ep <= ep + 1; wp <= 0;
                                caddr <= bebase(ep + 1);
                            end
                        end else begin                   // 实体内下一词
                            wp <= wp + 1; caddr <= caddr + 1;
                        end
                    end else if (out_valid && !out_take)
                        stalls <= stalls + 1;            // 装配侧连拍吃不下
                end
                default: st <= S_IDLE;
            endcase
            if (wr_en) slice_mem[wr_addr] <= wr_data;
        end
    end
endmodule
`default_nettype wire