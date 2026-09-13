`timescale 1ps/1ps
// head_vprune LOCKSTEP 对账: 产品 head_vprune (vocab_prune+output_head 产品版)
//                     × SF 镜像 head_vprune_sf (vocab_prune_sf 打包 + output_head_sf KT)
// 固定 2000 拍随机流 (head_go 间歇 / acc / xext 随机 / out_take 随机), 全输出逐拍比对。
module head_vprune_lockstep_tb;
    localparam VOC = 32, GRP = 8, BB = 16, MAXE = 8, K = 3;
    reg clk = 0, rst_n = 0, head_go = 0, out_take = 0;
    reg [BB-1:0] acc = 0;
    reg [3:0] xext = 0;
    wire out_valid_p, out_valid_s, token_done_p, token_done_s;
    wire [BB-1:0] out_score_p, out_score_s;
    wire [($clog2((2*MAXE+1)*GRP))-1:0] out_token_p, out_token_s;
    wire [31:0] round_p, round_s, stalls_p, stalls_s, scanned_p, scanned_s, lbw_p, lbw_s, ubw_p, ubw_s, ncad_p, ncad_s;
    wire [($clog2(VOC/GRP))-1:0] peak_g_p, peak_g_s;

    head_vprune #(.VOC(VOC), .GRP(GRP), .BB(BB), .MAXE(MAXE), .K(K)) U_P(
        .clk(clk), .rst_n(rst_n), .head_go(head_go), .acc(acc), .xext(xext),
        .out_valid(out_valid_p), .out_score(out_score_p), .out_token(out_token_p),
        .out_take(out_take), .token_done(token_done_p), .round(round_p),
        .stalls(stalls_p), .scanned(scanned_p), .peak_g(peak_g_p),
        .lbw(lbw_p), .ubw(ubw_p), .ncad(ncad_p));
    head_vprune_sf #(.VOC(VOC), .GRP(GRP), .BB(BB), .MAXE(MAXE), .K(K)) U_S(
        .clk(clk), .rst_n(rst_n), .head_go(head_go), .acc(acc), .xext(xext),
        .out_valid(out_valid_s), .out_score(out_score_s), .out_token(out_token_s),
        .out_take(out_take), .token_done(token_done_s), .round(round_s),
        .stalls(stalls_s), .scanned(scanned_s), .peak_g(peak_g_s),
        .lbw(lbw_s), .ubw(ubw_s), .ncad(ncad_s));

    always #5 clk = ~clk;
    integer mism = 0, cyc;
    reg [31:0] lcg;
    function [31:0] rnd; begin lcg = lcg*1664525 + 1013904223; rnd = lcg; end endfunction

    always @(posedge clk) begin
        if (out_valid_p !== out_valid_s || out_score_p !== out_score_s ||
            out_token_p !== out_token_s || token_done_p !== token_done_s ||
            round_p !== round_s || stalls_p !== stalls_s || scanned_p !== scanned_s ||
            peak_g_p !== peak_g_s || lbw_p !== lbw_s || ubw_p !== ubw_s || ncad_p !== ncad_s)
            mism = mism + 1;
    end

    initial begin
        $display("START");
        lcg = 32'hF0D0_2026; cyc = 0;
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (1000) begin
            @(posedge clk);
            head_go  = (rnd() & 63) == 0;
            acc      = rnd();
            xext     = rnd() & 4'hF;
            out_take = (rnd() & 1) != 0;
            cyc = cyc + 1;
        end
        if (mism == 0) $display("LOCKSTEP head_vprune PASS (%0d cyc, 全输出逐拍一致)", cyc);
        else begin $display("LOCKSTEP MISMATCH count=%0d (xext=%0d)", mism, xext); $finish(1); end
        $finish;
    end
endmodule
`default_nettype wire