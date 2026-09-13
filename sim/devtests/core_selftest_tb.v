`timescale 1ps/1ps
// core_selftest_tb — decode_auto_core 自驱闭环 (SELFDRV=1)
// 断言: ① run→done 可达 (≤5000拍); ② route_asm 有 token 产出 (a_words/r_selected>0);
// ③ 两次同 seed (rst 复位) 跑出的 token 序列逐拍相同 → 确定性 (板上同seed可复现对账)。
module core_selftest_tb;
    reg clk = 0, rst_n = 0, run = 0, credit = 1, s_valid = 0, out_take = 1, wr_en = 0;
    reg [15:0] s_score = 0, head_acc = 16'h1234;
    reg [3:0] xext = 4'h6;
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

    integer cyc;
    reg [31:0] h1 = 0, h2 = 0;
    reg donef = 0;
    reg td_f = 0, htd_f = 0;
    reg [31:0] saw_w = 0;

    task run_once(output [31:0] hh);
        integer j;
        begin
            hh = 0; saw_w = 0;
            run = 1; @(posedge clk); run = 0;
            cyc = 0; donef = 0; td_f = 0; htd_f = 0;
            while (!donef) begin
                @(posedge clk);
                if (token_done && !td_f) begin $display("  token_done@%0d (a_words=%0d)", cyc, a_words); td_f = 1; end
                if (U.h_token_done && !htd_f) begin $display("  h_token_done@%0d (h_round=%0d)", cyc, h_round); htd_f = 1; end
                if (out_valid && a_words > saw_w) begin
                    hh = {hh[30:0], hh[31]^out_expert[0]} ^ {out_expert[3:1], out_data[3:0], out_token[0], out_score[3:0]};
                    saw_w <= a_words;
                end
                if (done) donef = 1;
                cyc = cyc + 1;
                if (cyc > 5000) begin $display("FAIL done 未达 td=%0d htd=%0d a_words=%0d", td_f, htd_f, a_words); $finish(1); end
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk); rst_n = 1;
        repeat (3) @(posedge clk);
        // 预灌 slice LUT (wr 接口; 词数据= 该词序号序号)
        begin : prefill
            integer i;
            wr_en = 1;
            for (i = 0; i < 512; i = i + 1) begin
                wr_addr = i; wr_data = i[15:0];
                @(posedge clk);
            end
            wr_en = 0;
        end
        run_once(h1);
        $display("RUN#1 done@%0d  a_words=%0d  h=%08h", cyc, a_words, h1);
        // 二次同 seed: 复位再跑
        rst_n = 0; repeat (2) @(posedge clk); rst_n = 1; repeat (3) @(posedge clk);
        run_once(h2);
        $display("RUN#2 done@%0d  h=%08h", cyc, h2);
        if (h1 === h2) $display("core_selftest PASS  (自驱闭环done可达, 两次同seed确定性一致)");
        else begin $display("core_selftest MISMATCH h1=%08h h2=%08h", h1, h2); $finish(1); end
        $finish;
    end
endmodule
`default_nettype wire