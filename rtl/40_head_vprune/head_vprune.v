`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// head_vprune.v — M24 词表剪枝→输出头 真接线: vocab_prune 候选窗路由输出头只扫候选
//
// 契约 (board-1g-k3-frozen.md §9 embed/output 接入 "词表剪枝候选集"):
//   M19 输出头每 decode 步扫全词表 logits; M22 证明候选窗 [lbw,ubw)=[G-xe,G+xe]×GRP
//   恒 ⊇ 真 top-K (fk 周期仅 a mod 23; 最小安全半径 xmin=6) ⇒ 只扫候选仍得同一 top-K。
//   本件 = 接线: 输出头按 窗内相对序 扫 ncad 个候选 (scan_end=ncad-1, 流式喂
//   in_logit = fk(acc, cand[cur]) — cand[] 恰为 [lbw..ubw) 实词号, cur=头所在相对位),
//   头吐 top-K 为窗内相对下标 → 消费侧加 lbw 还原真词号。窗口/词号全由硬件 (vocab_prune
//   组合) 实时给出, 不靠 TB 预排。
//   M24 TB 把本件接在 M23 真引擎链后: acc = MAC 阵列会话实算累计, 全链闭环。
//   (M19 增 scan_end 口: 恒全量时 = VOC-1, M19/M21 回归保持原语义.)
//────────────────────────────────────────────────────────────────────────────
module head_vprune #(
    parameter VOC  = 512,     // 词表规模
    parameter GRP  = 8,       // 组大小
    parameter BB   = 16,      // acc/logits 位宽
    parameter MAXE = 8,       // 窗半径上限 (cand 表容量 = (2*MAXE+1)*GRP)
    parameter K    = 3        // top-K
)(
    input  wire clk, rst_n,
    input  wire head_go,                       // 输出头启动脉冲 (会话 acc 可用后)
    input  wire [BB-1:0] acc,                  // 引擎会话累加 (logits 代理输入)
    input  wire [3:0]    xext,                 // 候选窗半径 (0..MAXE)
    // ── 输出头 top-K 出口 (窗内相对下标, 消费侧 +lbw) ──
    output wire          out_valid,
    output wire [BB-1:0] out_score,
    output wire [$clog2((2*MAXE+1)*GRP)-1:0] out_token,
    input  wire          out_take,
    output wire          token_done,
    output wire [5:0]    round,
    output wire [31:0]   stalls, scanned,
    // ── 剪枝窗观测 ──
    output wire [$clog2(VOC/GRP)-1:0] peak_g,
    output wire [31:0] lbw, ubw, ncad
);
    localparam NG  = VOC/GRP;
    localparam CAP = (2*MAXE+1)*GRP;
    localparam WV  = $clog2(CAP);
    localparam RNDW = 6;

    // 同 M22 的 logits 代理 (组峰用 fk; 头扫候选流也用同一 fk, 保持同源)
    function integer fk(input integer a, input integer x);
        fk = (a*7 + x*17) % 23;
    endfunction

    wire [$clog2(NG)-1:0] g_w;
    wire [31:0] ncad_w;
    wire [$clog2(VOC)-1:0] cand_w [0:CAP-1];

    vocab_prune #(.VOC(VOC), .GRP(GRP), .BB(BB), .MAXE(MAXE)) VP(
        .acc(acc), .xext(xext), .G(g_w), .ncad(ncad_w), .cand(cand_w)
    );
    assign peak_g = g_w;
    assign lbw = (g_w > xext) ? (g_w - xext)*GRP : 0;
    assign ubw = (((g_w + xext + 1)*GRP) > VOC) ? VOC : (g_w + xext + 1)*GRP;
    assign ncad = ncad_w;

    // 扫描终点 = 候选尾 (ncad-1); 候选流按 cand[cur] 实词号喂 logit
    wire [WV-1:0] se_w  = (ncad_w > 0) ? ncad_w[WV-1:0] - 1'b1 : 0;
    wire [WV-1:0] oh_cur;
    wire oh_td;
    wire [BB-1:0] oh_logit_int = (oh_cur < ncad_w[WV-1:0]) ? fk(acc, cand_w[oh_cur]) : 0;

    // 扫描源: head_go 脉冲 → 持续 in_valid 直到 token_done (窗内流, 头内部取拍)
    reg scan_b = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) scan_b <= 1'b0;
        else if (head_go) scan_b <= 1'b1;
        else if (oh_td) scan_b <= 1'b0;

    output_head #(.TN(1), .VOC(CAP), .K(K), .BB(BB), .RNDW(RNDW)) OH(
        .clk(clk), .rst_n(rst_n), .go(head_go),
        .in_valid(scan_b), .in_logit(oh_logit_int), .in_take(),
        .out_valid(out_valid), .out_score(out_score), .out_token(out_token), .out_take(out_take),
        .scan_end(se_w),
        .token_done(oh_td), .cur_word(oh_cur),
        .tok_idx(), .round(round), .stalls(stalls), .scanned(scanned)
    );
    assign token_done = oh_td;
endmodule
`default_nettype wire