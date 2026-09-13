`timescale 1ps/1ps
// route_asm LOCKSTEP 对账: 产品 route_asm (router_sel+assembler) × SF route_asm_sf
// (router_sel_sf 全并行插入实现 + 同 assembler)。随机流 (间歇 go / s流 / 背压 / 权重预灌)
// 2000拍, 全输出逐拍比对。激励一律非阻塞 (δ-cycle 卫生)。
module route_asm_lockstep_tb;
    localparam EX = 16, TOP = 4, EW = 8, NL = 4, SW = 16, RNDW = 32;
    reg clk = 0, rst_n = 0, go = 0, credit = 1, s_valid = 0, out_take = 0, wr_en = 0;
    reg [SW-1:0] s_score = 0, wr_data = 0;
    reg [$clog2(NL*EX*EW)-1:0] wr_addr = 0;
    wire out_valid_p, out_valid_s, a_layer_done_p, a_layer_done_s, r_layer_done_p, r_layer_done_s;
    wire token_done_p, token_done_s, r_token_done_p, r_token_done_s, r_out_valid_p, r_out_valid_s;
    wire [SW-1:0] out_data_p, out_data_s;
    wire [$clog2(EX)-1:0] out_expert_p, out_expert_s, r_cur_p, r_cur_s;
    wire [31:0] r_round_p, r_round_s, r_stalls_p, r_stalls_s, a_stalls_p, a_stalls_s,
                r_selected_p, r_selected_s, a_words_p, a_words_s;
    wire [RNDW-1:0] a_round_p, a_round_s;
    wire [$clog2(NL)-1:0] a_lay_idx_p, a_lay_idx_s;

    route_asm #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW), .RNDW(RNDW)) U_P(
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_take(out_take), .out_valid(out_valid_p), .out_data(out_data_p), .out_expert(out_expert_p),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .a_layer_done(a_layer_done_p), .r_layer_done(r_layer_done_p),
        .token_done(token_done_p), .r_token_done(r_token_done_p),
        .r_round(r_round_p), .a_round(a_round_p), .a_lay_idx(a_lay_idx_p),
        .r_cur(r_cur_p), .r_out_valid(r_out_valid_p),
        .r_stalls(r_stalls_p), .a_stalls(a_stalls_p), .r_selected(r_selected_p), .a_words(a_words_p));
    route_asm_sf #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW), .RNDW(RNDW)) U_S(
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_take(out_take), .out_valid(out_valid_s), .out_data(out_data_s), .out_expert(out_expert_s),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .a_layer_done(a_layer_done_s), .r_layer_done(r_layer_done_s),
        .token_done(token_done_s), .r_token_done(r_token_done_s),
        .r_round(r_round_s), .a_round(a_round_s), .a_lay_idx(a_lay_idx_s),
        .r_cur(r_cur_s), .r_out_valid(r_out_valid_s),
        .r_stalls(r_stalls_s), .a_stalls(a_stalls_s), .r_selected(r_selected_s), .a_words(a_words_s));

    always #5 clk = ~clk;
    integer mism = 0, cyc, snap = 0;
    reg [31:0] lcg;
    function [31:0] rnd; begin lcg = lcg*1664525 + 1013904223; rnd = lcg; end endfunction

    always @(posedge clk) begin
        if (out_valid_p !== out_valid_s || out_data_p !== out_data_s || out_expert_p !== out_expert_s ||
            a_layer_done_p !== a_layer_done_s || r_layer_done_p !== r_layer_done_s ||
            token_done_p !== token_done_s || r_token_done_p !== r_token_done_s ||
            r_round_p !== r_round_s || a_round_p !== a_round_s || a_lay_idx_p !== a_lay_idx_s ||
            r_cur_p !== r_cur_s || r_out_valid_p !== r_out_valid_s ||
            r_stalls_p !== r_stalls_s || a_stalls_p !== a_stalls_s ||
            r_selected_p !== r_selected_s || a_words_p !== a_words_s) mism = mism + 1;
    end

    initial begin
        lcg = 32'hB00B_1525; cyc = 0;
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (2000) begin
            @(posedge clk);
            go       <= (rnd() & 63) == 0;
            credit   <= (rnd() & 1) != 0;
            s_valid  <= (rnd() & 3) != 0;
            s_score  <= rnd();
            out_take <= (rnd() & 1) != 0;
            wr_en    <= (rnd() & 7) == 0;
            wr_addr  <= rnd();
            wr_data  <= rnd();
            cyc = cyc + 1;
        end
        if (mism == 0) $display("LOCKSTEP route_asm PASS (%0d cyc, 全输出逐拍一致)", cyc);
        else begin $display("LOCKSTEP MISMATCH count=%0d", mism); $finish(1); end
        $finish;
    end
endmodule
`default_nettype wire