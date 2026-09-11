`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// route_asm_tb.v — M20 选→装配 两级链验收
//
// 场景: 源喂每层 e_score (credit 门) → router 选 top-T → 吐表即交 assembler →
//       assembler 依选中序拉实体块 EW 词吐流。层 barrier: assembler 层拉完
//       → 源才灌下一层。背压练习:
//   L0  全速
//   L1  灌续中 router credit 断 3 拍 (选侧停拍)
//   L2  装配吐期 out_take 1-in-2 (装配侧停拍)
// 对账: 装配吐流 (专家号+词值) == 黄金 (独立全排序); router/assembler 双侧
//       round==1、token_done、停顿>0、字数/条数吻合。
//────────────────────────────────────────────────────────────────────────────
module route_asm_tb;
    localparam EX = 32, TOP = 8, EW = 8, NL = 3, SW = 16;

    reg clk = 1, rst_n = 0, go = 0;
    reg credit = 1, s_valid = 0;
    wire [SW-1:0] s_score;
    reg out_take = 1;
    wire out_valid;
    wire [SW-1:0] out_data;
    wire [$clog2(EX)-1:0] out_expert;
    reg wr_en = 0;
    reg [$clog2(NL*EX*EW)-1:0] wr_addr = 0;
    reg [SW-1:0] wr_data = 0;
    wire a_layer_done, r_layer_done, token_done, r_token_done;
    wire [7:0] r_round_w;
    wire [$clog2(NL)-1:0] a_lay_w;
    wire [$clog2(EX)-1:0] r_cur_w;
    wire r_out_valid_w;
    wire [5:0] a_round_w2ph;
    wire [31:0] r_stalls_w, a_stalls_w, r_sel_w, a_words_w;

    route_asm #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW)) u(
        .clk(clk), .rst_n(rst_n), .go(go),
        .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_take(out_take), .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .a_layer_done(a_layer_done), .r_layer_done(r_layer_done),
        .token_done(token_done), .r_token_done(r_token_done),
        .r_round(r_round_w), .a_round(a_round_w2ph), .a_lay_idx(a_lay_w),
        .r_cur(r_cur_w), .r_out_valid(r_out_valid_w),
        .r_stalls(r_stalls_w), .a_stalls(a_stalls_w),
        .r_selected(r_sel_w), .a_words(a_words_w)
    );
    wire [5:0] a_round_w2 = a_round_w2ph;

    always #5 clk = ~clk;

    // ── 分值/词值 ──
    function [SW-1:0] s_v(input integer L, input integer k);
        s_v = (L*7 + k/4) & 16'hFFFF;
    endfunction
    function [SW-1:0] sw_val(input integer L, input integer e, input integer w);
        sw_val = (L*131 + e*17 + w) & 16'hFFFF;
    endfunction

    // 源配对: 分值 = 当前层 × 当前灌收号 (M16 s_sel=f(pl) 同构)
    reg [7:0] srcL = 0;
    assign s_score = s_v(srcL, r_cur_w);

    // ── 黄金 top-T (平局 idx 小者先) ──
    integer gsel_all [0:NL*TOP-1];
    task automatic gold_all();
        integer L, j, k, bi;
        integer doneg [0:EX-1];
        for (L = 0; L < NL; L = L + 1) begin
            for (k = 0; k < EX; k = k + 1) doneg[k] = 0;
            for (j = 0; j < TOP; j = j + 1) begin
                bi = -1;
                for (k = 0; k < EX; k = k + 1)
                    if (!doneg[k])
                        if (bi < 0 ||
                            (s_v(L, k) > s_v(L, bi)) ||
                            (s_v(L, k) == s_v(L, bi) && k < bi)) bi = k;
                doneg[bi] = 1;
                gsel_all[L*TOP + j] = bi;
            end
        end
    endtask

    // ── 装配吐流对账 monitor ──
    integer emc = 0, wT = 0, ecur = -1, sei, eks;
    reg seq_bad = 0;
    always @(posedge clk) begin
        if (ecur != a_lay_w) begin emc = 0; ecur = a_lay_w; end
        if (out_valid && out_take) begin
            sei = emc / EW;
            eks = gsel_all[ecur*TOP + sei];
            if (out_expert !== eks)
                seq_bad = 1;
            if (out_data !== sw_val(ecur, eks, emc % EW))
                seq_bad = 1;
            emc = emc + 1;
            wT = wT + 1;
        end
    end

    // ── L2 装配吐期 1-in-2 慢取 (装配侧背压) ──
    reg [3:0] tgen = 0;
    always @(posedge clk) tgen <= tgen + 1;
    always @(negedge clk) begin
        if ((a_lay_w == 2) && out_valid) out_take = tgen[0];
        else out_take = 1;
    end

    // ── 收尾观测 ──
    reg td_a = 0, td_r = 0;
    always @(posedge clk) begin
        if (token_done) td_a = 1;
        if (r_token_done) td_r = 1;
    end

    initial begin
        integer L, e, w;
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        // 预灌切片 LUT
        for (L = 0; L < NL; L = L + 1)
            for (e = 0; e < EX; e = e + 1)
                for (w = 0; w < EW; w = w + 1) begin
                    @(negedge clk);
                    wr_en = 1;
                    wr_addr = L*EX*EW + e*EW + w;
                    wr_data = sw_val(L, e, w);
                end
        @(negedge clk);
        wr_en = 0;
        gold_all();
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;
        // 逐层灌 e_score (源屏障: 上一层装配拉完才喂下一层)
        for (L = 0; L < NL; L = L + 1) begin
            if (L > 0) begin
                while (!a_layer_done) @(posedge clk);   // 等前层装配完
                @(posedge clk);
            end
            srcL = L;
            @(negedge clk);
            s_valid = 1;
            if (L == 1) begin                            // L1 选侧断信用 3 拍
                while (r_cur_w < 3) @(negedge clk);
                credit = 0;
                repeat (6) @(negedge clk);
                credit = 1;
            end
            while (!r_out_valid_w) @(negedge clk);       // 灌完 → 吐表
            @(negedge clk);
            s_valid = 0;
        end
        while (!(td_a && td_r)) @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        // ── 验收 ──
        if (seq_bad) begin
            $display("FAIL 装配吐流对账违例"); $finish;
        end
        if (wT !== NL*TOP*EW) begin
            $display("FAIL 吐词 %0d != %0d", wT, NL*TOP*EW); $finish;
        end
        if (a_words_w !== wT) begin
            $display("FAIL assembler 字数 %0d != 观测 %0d", a_words_w, wT); $finish;
        end
        if (r_sel_w !== NL*TOP) begin
            $display("FAIL router 吐条 %0d != %0d", r_sel_w, NL*TOP); $finish;
        end
        if (r_stalls_w == 0) begin
            $display("FAIL router 无停顿"); $finish;
        end
        if (a_stalls_w == 0) begin
            $display("FAIL assembler 无停顿"); $finish;
        end
        if (r_round_w !== 1 || a_round_w2 !== 1) begin
            $display("FAIL round r=%0d a=%0d", r_round_w, a_round_w2); $finish;
        end
        if (a_lay_w !== NL-1) begin
            $display("FAIL a_lay_idx=%0d", a_lay_w); $finish;
        end
        if (!(td_a && td_r)) begin
            $display("FAIL 双侧 token_done 未到"); $finish;
        end
        $display("== M20 route_asm: 层%0d round r%0d/a%0d 吐词%0d 选条%0d 停顿 r%0d/a%0d 序违例%0d ==",
                 a_lay_w, r_round_w, a_round_w2, wT, r_sel_w, r_stalls_w, a_stalls_w, seq_bad);
        $display("##### ALL PASS: M20 选→装配链 · router top-T 吐表直交 assembler · 双向背压+层barrier 不丢不序 #####");
        $finish;
    end
endmodule
`default_nettype wire