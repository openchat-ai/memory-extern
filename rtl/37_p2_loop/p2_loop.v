`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// p2_loop.v — M21 P2 算闭环骨架: 选→装配→层引擎→输出头 四级链 (完整解码一步)
//
// 契约 (board-1g-k3-frozen.md): 
//   每 token 解码一步 = NL 层前向 + 词表扫 top-K:
//     e_score(credit) → router 顶T → assembler 按选中序抽实体块 → 词流喂
//     engine_stub (层引擎段骨架) 吃词求和, 每层 TOP*EW 词 → layer_done 即源侧
//     屏障 (下一层 e_score 才能灌), NL 层完 token_done → 输出头 go → 扫 VOC
//     logits 取 top-K (token 出口 = 整个会话出口)。装配按层拉完才放行源, 与
//     assembler 自动 TAKE 严格衔接, 不丢不序。
//   背压链: 选侧 credit (router 停), 装配侧 out_take 上游, 引擎侧 credit (engine 慢取),
//          输出头吞吐 out_take。
//────────────────────────────────────────────────────────────────────────────
module p2_loop #(
    parameter EX  = 32,     // 候选专家/层
    parameter TOP = 8,      // 每层选出
    parameter EW  = 8,      // 每实体权重词数
    parameter NL  = 3,      // 座席层
    parameter SW  = 16,     // 词位宽
    parameter VOC = 64,     // 词表规模 (FAST 替身, 输出头节留)
    parameter K   = 3,      // top-K
    parameter BB  = 16,     // logits 位宽
    parameter AW  = 16      // 引擎累加截位
)(
    input  wire clk, rst_n, go,
    // router 侧 (e_score 灌入)
    input  wire credit, s_valid,
    input  wire [SW-1:0] s_score,
    // 切片双口 (TB 预灌)
    input  wire wr_en,
    input  wire [$clog2(NL*EX*EW)-1:0] wr_addr,
    input  wire [SW-1:0] wr_data,
    // 引擎侧
    input  wire engine_credit,
    // 输出头侧 (logits 流由 TB 依 acc 派生)
    input  wire oh_go, oh_valid,
    input  wire [BB-1:0] oh_logit,
    input  wire oh_out_take,
    output wire oh_in_take,
    output wire oh_out_valid,
    output wire [BB-1:0] oh_out_score,
    output wire [$clog2(VOC)-1:0] oh_out_token,
    output wire oh_token_done,
    // 输出头观测
    output wire [$clog2(VOC)-1:0] oh_cur,
    output wire [31:0] oh_scanned,
    // 状态/统计 (观测)
    output wire [$clog2(EX)-1:0] r_cur,
    output wire r_out_valid,
    output wire r_token_done, a_token_done, e_token_done, e_layer_done,
    output wire [7:0] r_round,
    output wire [RNDW-1:0] a_round, oh_round,
    output wire [$clog2(NL)-1:0] e_lay,
    output wire [AW-1:0] e_acc,
    output wire [31:0] r_stalls, a_stalls, oh_stalls,
    output wire [31:0] r_selected, a_words, e_words
);
    localparam RNDW = 6;
    wire a_out_valid, a_take_e;
    wire [SW-1:0] a_out_data;
    wire [$clog2(EX)-1:0] a_out_expert;

    route_asm #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW)) RA(
        .clk(clk), .rst_n(rst_n), .go(go),
        .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_take(a_take_e),
        .out_valid(a_out_valid), .out_data(a_out_data), .out_expert(a_out_expert),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .a_layer_done(), .r_layer_done(),
        .token_done(a_token_done), .r_token_done(r_token_done),
        .r_round(r_round), .a_round(a_round),
        .a_lay_idx(), .r_cur(r_cur),
        .r_out_valid(r_out_valid),
        .r_stalls(r_stalls), .a_stalls(a_stalls),
        .r_selected(r_selected), .a_words(a_words)
    );

    engine_stub #(.TOP(TOP), .EW(EW), .NL(NL), .SW(SW), .AW(AW)) ES(
        .clk(clk), .rst_n(rst_n),
        .credit(engine_credit),
        .in_valid(a_out_valid), .in_data(a_out_data),
        .in_take(a_take_e),
        .layer_done(e_layer_done), .token_done(e_token_done),
        .e_lay(e_lay), .acc(e_acc), .words(e_words)
    );

    output_head #(.TN(1), .VOC(VOC), .K(K), .BB(BB), .RNDW(RNDW)) OH(
        .clk(clk), .rst_n(rst_n), .go(oh_go),
        .in_valid(oh_valid), .in_logit(oh_logit), .in_take(oh_in_take),
        .out_valid(oh_out_valid), .out_score(oh_out_score), .out_token(oh_out_token),
        .out_take(oh_out_take),
        .token_done(oh_token_done), .cur_word(oh_cur),
        .tok_idx(), .round(oh_round), .stalls(oh_stalls), .scanned(oh_scanned)
    );
endmodule
`default_nettype wire