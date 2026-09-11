`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// route_asm.v — M20 选→装配 两级链: router 先行 top-T 选择 + 专家装配件
//
// 契约 (router_sel/assembler 逐件已验):
//   每层: e_score 流 (credit 门) → router 收 EX 选 top-T →  吐表逐条经
//   out_valid/out_take 交给 assembler → assembler 依选中序从切片 LUT 取
//   实体块 EW 词吐流 (→ GEMM 段)。层 barrier: assembler 层拉完 → 源才能灌
//   下一层 e_score (router 已在 COLL. 自行等待); NL 层 → 双侧 token_done、
//   round++。本件 = 装配前端整块 (P2 算 "先选后抽" 时序契约验证)。
//────────────────────────────────────────────────────────────────────────────
module route_asm #(
    parameter EX = 32,      // 候选专家/层
    parameter TOP = 8,      // 每层选出
    parameter EW  = 8,      // 每实体权重词数
    parameter NL  = 3,      // 座席层/会话
    parameter SW  = 16,     // 词位宽
    parameter RNDW = 32     // M38: 与 assembler 对齐 (6→32); 须在端口宽引用前声明
)(
    input  wire clk, rst_n, go,
    // router 侧 (e_score 灌入)
    input  wire credit,
    input  wire s_valid,
    input  wire [SW-1:0] s_score,
    // assembler 侧 (实体权重流 → GEMM 段)
    input  wire out_take,
    output wire out_valid,
    output wire [SW-1:0] out_data,
    output wire [$clog2(EX)-1:0] out_expert,
    // 切片双口 (TB 预灌 / P1 装载)
    input  wire wr_en,
    input  wire [$clog2(NL*EX*EW)-1:0] wr_addr,
    input  wire [SW-1:0] wr_data,
    // 状态/统计
    output wire a_layer_done, r_layer_done,
    output wire token_done, r_token_done,
    output wire [31:0] r_round,
    output wire [RNDW-1:0] a_round,
    output wire [$clog2(NL)-1:0] a_lay_idx,
    output wire [$clog2(EX)-1:0] r_cur,
    output wire r_out_valid,                            // router 吐表中 (源可停)
    output wire [31:0] r_stalls, a_stalls,
    output wire [31:0] r_selected, a_words
);
    wire r_out_v;
    wire [$clog2(EX)-1:0] r_out_i;
    wire [SW-1:0] r_out_s;
    wire a_take;

    router_sel #(.EX(EX), .TOP(TOP), .SW(SW), .NL(NL)) R(
        .clk(clk), .rst_n(rst_n), .go(go),
        .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_valid(r_out_v), .out_idx(r_out_i), .out_score(r_out_s), .out_take(a_take),
        .layer_done(r_layer_done), .token_done(r_token_done), .round(r_round),
        .cur_idx(r_cur),
        .layers(), .selected(r_selected), .stalls(r_stalls)
    );
    assign r_out_valid = r_out_v;

    assembler #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW)) A(
        .clk(clk), .rst_n(rst_n), .go(go),
        .in_valid(r_out_v), .in_idx(r_out_i), .in_take(a_take),
        .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert), .out_take(out_take),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .layer_done(a_layer_done), .token_done(token_done),
        .lay_idx(a_lay_idx), .round(a_round), .stalls(a_stalls), .words(a_words)
    );
endmodule
`default_nettype wire