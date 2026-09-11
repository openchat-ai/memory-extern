`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// assembler_tb.v — M18 专家装配件验收
//
// 场景: router 逐层吐 top-T (黄金选择: 四连同分逼平局断序, idx 小者先) →
//       装配件收 TOP 条 → 依序逐实体取 EW 词吐流; 切片=LUT 预灌 (P1 换真装载).
// 背压练习 (不丢不序不乱):
//   R0  L0: 全速
//   R1  L1: ① TAKE 期上游断灌 5 拍 (in_valid=0); ② EMIT 期 out_take 1-in-2
//           → 装配侧停拍 (stall 计数)
//   R2  L2: 全速
// 对账: 每层吐流专家号==选出序 (gold), 每词==切片值; 全程零丢/零重; 字数
//       = NL*TOP*EW == DUT 内部 words; token_done 后 round==1。
//────────────────────────────────────────────────────────────────────────────
module assembler_tb;
    localparam EX = 32, TOP = 8, EW = 8, NL = 3, SW = 16;

    reg clk = 1, rst_n = 0, go = 0;
    reg in_valid = 0;
    reg [$clog2(EX)-1:0] in_idx = 0;
    wire in_take;
    reg out_take = 1;
    wire out_valid;
    wire [SW-1:0] out_data;
    wire [$clog2(EX)-1:0] out_expert;
    reg wr_en = 0;
    reg [$clog2(NL*EX*EW)-1:0] wr_addr = 0;
    reg [SW-1:0] wr_data = 0;
    wire layer_done, token_done;
    wire [$clog2(NL)-1:0] lay_w;
    wire [5:0] round_w;
    wire [31:0] stalls_w, words_w;

    assembler #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW)) u(
        .clk(clk), .rst_n(rst_n), .go(go),
        .in_valid(in_valid), .in_idx(in_idx), .in_take(in_take),
        .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert), .out_take(out_take),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .layer_done(layer_done), .token_done(token_done),
        .lay_idx(lay_w), .round(round_w), .stalls(stalls_w), .words(words_w)
    );

    always #5 clk = ~clk;

    // ── 分值 (选择竞分, 四连同分→平局) 与 切片词值 (实体块) ──
    function [SW-1:0] ssc(input integer L, input integer k);
        ssc = (L*7 + k/4) & 16'hFFFF;
    endfunction
    function [SW-1:0] sw_val(input integer L, input integer e, input integer w);
        sw_val = (L*131 + e*17 + w) & 16'hFFFF;
    endfunction

    // ── 黄金: 全部层 top-TOP (平局 idx 小者先) ──
    integer gsel_all [0:NL*TOP-1];
    task automatic gold_all();
        integer L, jj, kk, bi;
        integer doneg [0:EX-1];
        for (L = 0; L < NL; L = L + 1) begin
            for (kk = 0; kk < EX; kk = kk + 1) doneg[kk] = 0;
            for (jj = 0; jj < TOP; jj = jj + 1) begin
                bi = -1;
                for (kk = 0; kk < EX; kk = kk + 1)
                    if (!doneg[kk])
                        if (bi < 0 ||
                            (ssc(L, kk) > ssc(L, bi)) ||
                            (ssc(L, kk) == ssc(L, bi) && kk < bi)) bi = kk;
                doneg[bi] = 1;
                gsel_all[L*TOP + jj] = bi;
            end
        end
    endtask

    // ── 吐流对账 monitor (posedge 读 DUT 组合/寄存, 落后一拍语义锁死逐词) ──
    integer lc = 0, wc_total = 0, curL = -1, sidx, exp_e;
    reg seq_bad = 0, tok_seen = 0;
    integer exp_w;
    always @(posedge clk) begin
        if (curL != lay_w) begin lc = 0; curL = lay_w; end
        if (out_valid && out_take) begin
            sidx  = lc / EW;
            exp_e = gsel_all[curL*TOP + sidx];
            exp_w = sw_val(curL, exp_e, lc % EW);
            if (out_expert !== exp_e)
                seq_bad = 1;
            if (out_data !== exp_w)
                seq_bad = 1;
            lc = lc + 1;
            wc_total = wc_total + 1;
        end
        if (token_done) tok_seen = 1;
    end

    // ── L1 装配期 1-in-2 慢取 (吐侧背压) ──
    reg [3:0] tgen = 0;
    always @(posedge clk) tgen <= tgen + 1;
    always @(negedge clk) begin
        if ((lay_w == 1) && out_valid) out_take = tgen[0];
        else out_take = 1;
    end

    initial begin
        integer L, e, w, tx;
        // 复位
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        // 预灌切片 LUT (P1 装载前替身)
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
        // 开工
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;
        // 逐层推 top-T
        for (L = 0; L < NL; L = L + 1) begin
            if (L > 0) begin                       // 等前层全吐完 (layer barrier)
                @(negedge clk);
                in_valid = 0;
                while (!layer_done) @(posedge clk);
            end
            for (tx = 0; tx < TOP; tx = tx + 1) begin
                @(negedge clk);
                in_valid = 0;
                in_idx = gsel_all[L*TOP + tx];
                if (L == 1 && tx == 4) repeat (5) @(negedge clk);   // 上游断灌 5 拍
                in_valid = 1;
                @(posedge clk);                    // 本拍消费
            end
            @(negedge clk);
            in_valid = 0;
        end
        // 等会话完工
        while (!tok_seen) @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        // ── 验收 ──
        if (seq_bad) begin
            $display("FAIL 专家号/词值对账有违例"); $finish;
        end
        if (wc_total !== NL*TOP*EW) begin
            $display("FAIL 吐词数 %0d != %0d", wc_total, NL*TOP*EW); $finish;
        end
        if (words_w !== wc_total) begin
            $display("FAIL DUT 内部字数 %0d != 观测 %0d", words_w, wc_total); $finish;
        end
        if (stalls_w == 0) begin
            $display("FAIL 装配侧无停顿(未碰到背压)"); $finish;
        end
        if (round_w !== 1) begin
            $display("FAIL round=%0d", round_w); $finish;
        end
        if (lay_w !== NL-1) begin
            $display("FAIL lay_idx=%0d", lay_w); $finish;
        end
        $display("== M18 assembler: 层%0d token1 round=%0d 词%0d/%0d 停顿%0d 序违例%0d ==",
                 lay_w, round_w, words_w, wc_total, stalls_w, seq_bad);
        $display("##### ALL PASS: M18 专家装配 · top-T→实体块依序吐流 · 上游断灌+装配侧背压不丢不序 #####");
        $finish;
    end
endmodule
`default_nettype wire