`timescale 1ps/1ps
// router_sel LOCKSTEP 对账: 产品 router_sel × SF 镜像 router_sel_sf
// 随机激励 (间歇 go / 随机 credit / s_valid / s_score / out_take) 跑固定 3000 拍,
// 全输出逐拍比对; 任一分歧即 mismatch。DONE = 无分歧 = SF 变换语义等价。
module router_sel_lockstep_tb;
    localparam EX = 16, TOP = 4, SW = 16, NL = 4;
    reg clk = 0, rst_n = 0, go = 0, credit = 1, s_valid = 0, out_take = 0;
    reg [SW-1:0] s_score = 0;
    wire [EX-1:0] _u; assign _u = 0;
    wire out_valid_p, out_valid_s, busy_p, busy_s, layer_done_p, layer_done_s, token_done_p, token_done_s;
    wire [3:0] out_idx_p, out_idx_s, cur_idx_p, cur_idx_s;
    wire [15:0] out_score_p, out_score_s;
    wire [31:0] round_p, round_s, layers_p, layers_s, selected_p, selected_s, stalls_p, stalls_s;

    router_sel #(.EX(EX), .TOP(TOP), .SW(SW), .NL(NL)) U_P(
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_valid(out_valid_p), .out_idx(out_idx_p), .out_score(out_score_p),
        .out_take(out_take), .busy(busy_p), .layer_done(layer_done_p), .token_done(token_done_p),
        .round(round_p), .cur_idx(cur_idx_p), .layers(layers_p), .selected(selected_p), .stalls(stalls_p));
    router_sel_sf #(.EX(EX), .TOP(TOP), .SW(SW), .NL(NL)) U_S(
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_valid(out_valid_s), .out_idx(out_idx_s), .out_score(out_score_s),
        .out_take(out_take), .busy(busy_s), .layer_done(layer_done_s), .token_done(token_done_s),
        .round(round_s), .cur_idx(cur_idx_s), .layers(layers_s), .selected(selected_s), .stalls(stalls_s));

    always #5 clk = ~clk;
    integer mism = 0, cyc;
    reg [31:0] lcg;
    function [31:0] rnd; begin lcg = lcg*1664525 + 1013904223; rnd = lcg; end endfunction

    always @(posedge clk) begin
        if (busy_p !== busy_s || out_valid_p !== out_valid_s ||
            out_idx_p !== out_idx_s || out_score_p !== out_score_s ||
            layer_done_p !== layer_done_s || token_done_p !== token_done_s ||
            round_p !== round_s || cur_idx_p !== cur_idx_s ||
            layers_p !== layers_s || selected_p !== selected_s || stalls_p !== stalls_s)
            mism = mism + 1;
    end

    initial begin
        lcg = 32'h5A11_CAFE; cyc = 0;
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (3000) begin
            @(posedge clk);
            go       = (rnd() & 127) == 0;             // 间隔 ~128 拍一 go
            credit   = (rnd() & 1) != 0;               // 50% 断面
            s_valid  = (rnd() & 3) != 0;               // 75% 有效拍
            s_score  = rnd();
            out_take = (rnd() & 1) != 0;               // 50% 吞
            cyc = cyc + 1;
        end
        if (mism == 0) $display("LOCKSTEP router_sel PASS (%0d cyc, 全输出逐拍一致)", cyc);
        else begin $display("LOCKSTEP MISMATCH count=%0d", mism); $finish(1); end
        $finish;
    end
endmodule
`default_nettype wire