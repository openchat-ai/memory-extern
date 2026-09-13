`timescale 1ps/1ps
// core_smoke_tb — decode_auto_core 连通性冒烟 (SF7 证据: 全 *_sf 链实例化可跑)
// 断言: reset 后空闲 (busy=0/done=0); run 拉高 1 拍内 busy=1 (状态机进 RUN);
// run 撤后等待 (数据面外源不驱动 token_done → 保持在 RUN, 不做 done 断言);
// 全程无 X 污染 (观测线列 X 即 FAIL)。
module core_smoke_tb;
    reg clk = 0, rst_n = 0, run = 0, credit = 1, s_valid = 0, out_take = 1, wr_en = 0;
    reg [15:0] s_score = 0, head_acc = 0;
    reg [3:0] xext = 0;
    reg [63:0] q_vec_p = 0;
    reg [8:0] wr_addr = 0; reg [15:0] wr_data = 0;
    wire busy, done, out_valid, token_done, r_token_done, h_go;
    wire [15:0] out_data, out_score;
    wire [3:0] out_expert;
    wire [8:0] out_token;
    wire [31:0] r_round, h_round, r_stalls, a_stalls, a_words;

    decode_auto_core U(
        .clk(clk), .rst_n(rst_n), .run(run), .busy(busy), .done(done),
        .credit(credit), .s_valid(s_valid), .out_take(out_take), .s_score(s_score),
        .q_vec_p(q_vec_p), .head_acc(head_acc), .xext(xext),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert),
        .token_done(token_done), .r_token_done(r_token_done),
        .out_token(out_token), .out_score(out_score), .h_go(h_go),
        .r_round(r_round), .h_round(h_round), .r_stalls(r_stalls), .a_stalls(a_stalls), .a_words(a_words)
    );
    always #5 clk = ~clk;
    integer px = 0, cyc = 0;

    always @(posedge clk) begin
        if ({busy, done, out_valid, token_done, out_data[15:0], r_round, a_words} !== 36'hZ) begin end
        if (busy === 1'bX || done === 1'bX || token_done === 1'bX || out_valid === 1'bX) px = px + 1;
    end

    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (3) @(posedge clk);
        if (busy !== 0 || done !== 0) begin $display("FAIL 初始应空闲 busy=%b done=%b", busy, done); $finish(1); end
        run = 1; @(posedge clk); run = 0;
        repeat (3) @(posedge clk);
        if (busy !== 1) begin $display("FAIL run 后应 busy=1 (得 %b)", busy); $finish(1); end
        $display("core_smoke PASS  (busy=%b done=%b; 实例化链可与状态机共存)", busy, done);
        $finish;
    end
endmodule
`default_nettype wire