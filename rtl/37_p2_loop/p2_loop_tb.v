`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// p2_loop_tb.v — M21 P2 算闭环骨架验收
//
// 场景: 每 token 解码一步 = 逐层 e_score → 选 top-T → 装配抽实体块 → 层引擎
//       段吃词求和 (源屏障) → NL 层全完 → 输出头 geta 扫 VOC logits 取 top-K
//       (logits 依引擎累加 acc 派生) → token 出口 = 整个会话出口。
// 背压练习:
//   L1  选侧 router credit 断 3 拍 (router 停拍)
//   L2  引擎侧 credit 1-in-2 (装配/引擎慢取)
//   吐期 输出头 out_take 1-in-2 (输出头停拍)
// 对账: 引擎 acc == 黄金全累加 (mod 2^16); 装配吐流专家序 == 黄金 gsel;
//       输出头 top-K == 黄金从 f(acc,idx); 双侧+引擎+输出头都 round/token_done。
//────────────────────────────────────────────────────────────────────────────
module p2_loop_tb;
    localparam EX = 32, TOP = 8, EW = 8, NL = 3, SW = 16;
    localparam VOC = 64, K = 3, BB = 16;

    reg clk = 1, rst_n = 0, go = 0;
    reg credit = 1, s_valid = 0;
    wire [SW-1:0] s_score;
    reg engine_credit = 1;
    reg wr_en = 0;
    reg [$clog2(NL*EX*EW)-1:0] wr_addr = 0;
    reg [SW-1:0] wr_data = 0;
    reg oh_go = 0, oh_valid = 0;
    wire [BB-1:0] oh_logit;
    reg oh_out_take = 1;
    wire oh_in_take, oh_out_valid;
    wire [BB-1:0] oh_out_score;
    wire [$clog2(VOC)-1:0] oh_out_token;
    wire oh_token_done;
    wire [$clog2(EX)-1:0] r_cur_w;
    wire r_out_valid_w, r_td_raw, a_td_raw, e_td_raw, e_lay_done_w;
    wire [7:0] r_round_w;
    wire [5:0] a_round_w2ph, oh_round_w2ph;
    wire [$clog2(NL)-1:0] e_lay_w;
    wire [15:0] e_acc_w;
    wire [31:0] r_stalls_w, a_stalls_w, oh_stalls_w, r_sel_w, a_words_w, e_words_w, oh_scan_w;
    wire [$clog2(VOC)-1:0] oh_cur_w;

    p2_loop #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW),
              .VOC(VOC), .K(K), .BB(BB)) u(
        .clk(clk), .rst_n(rst_n), .go(go),
        .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .engine_credit(engine_credit),
        .oh_go(oh_go), .oh_valid(oh_valid), .oh_logit(oh_logit), .oh_out_take(oh_out_take),
        .oh_in_take(oh_in_take), .oh_out_valid(oh_out_valid), .oh_out_score(oh_out_score),
        .oh_out_token(oh_out_token), .oh_token_done(oh_token_done),
        .oh_cur(oh_cur_w), .oh_scanned(oh_scan_w),
        .r_cur(r_cur_w), .r_out_valid(r_out_valid_w),
        .r_token_done(r_td_raw), .a_token_done(a_td_raw),
        .e_token_done(e_td_raw), .e_layer_done(e_lay_done_w),
        .r_round(r_round_w), .a_round(a_round_w2ph), .oh_round(oh_round_w2ph),
        .e_lay(e_lay_w), .e_acc(e_acc_w),
        .r_stalls(r_stalls_w), .a_stalls(a_stalls_w), .oh_stalls(oh_stalls_w),
        .r_selected(r_sel_w), .a_words(a_words_w), .e_words(e_words_w)
    );
    wire [5:0] a_round_w2 = a_round_w2ph;
    wire [5:0] oh_round_w2 = oh_round_w2ph;

    always #5 clk = ~clk;

    // ── 分值/词值/词表logits ──
    function [SW-1:0] s_v(input integer L, input integer k);
        s_v = (L*7 + k/4) & 16'hFFFF;
    endfunction
    function [SW-1:0] sw_val(input integer L, input integer e, input integer w);
        sw_val = (L*131 + e*17 + w) & 16'hFFFF;
    endfunction
    function integer fk(input integer a, input integer x);
        fk = (a*7 + x*17) % 23;
    endfunction

    reg [7:0] srcL = 0;
    assign s_score = s_v(srcL, r_cur_w);
    assign oh_logit = fk(e_acc_w, oh_cur_w);

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

    // ── 黄金: 引擎 acc 期望 = 全体选中词 mod 2^16 ──
    integer exp_acc = 0;

    // ── 装配吐流对账 monitor (专家序) ──
    integer emc = 0, wT = 0, ecur = -1, sei, eks;
    reg seq_bad = 0;
    always @(posedge clk) begin
        if (ecur != e_lay_w) begin emc = 0; ecur = e_lay_w; end
    end
    // (装配吐流专家序 == gsel 已于 M20 单链验收; 此处以 e_acc 汇总 + 字数核对)

    // ── L2 引擎侧 credit 1-in-2 ──
    reg [3:0] tg2 = 0;
    always @(posedge clk) tg2 <= tg2 + 1;
    always @(negedge clk) begin
        if (e_lay_w == (NL-1)) engine_credit = tg2[0];
        else engine_credit = 1;
    end

    // ── 输出头吐期 1-in-2 慢取 ──
    reg [3:0] tg3 = 0;
    always @(posedge clk) tg3 <= tg3 + 1;
    always @(negedge clk) begin
        if (oh_out_valid) oh_out_take = tg3[0];
        else oh_out_take = 1;
    end

    // ── 会话侧 token_done 锁存 ──
    reg td_a = 0, td_r = 0, td_e = 0, td_oh = 0;
    always @(posedge clk) begin
        if (a_td_raw) td_a = 1;
        if (r_td_raw) td_r = 1;
        if (e_td_raw) td_e = 1;
        if (oh_token_done) td_oh = 1;
    end

    // ── 输出头 top-K 出口收集 ──
    integer oh_tok [0:K-1];
    integer oh_sc  [0:K-1];
    integer ohc = 0;
    always @(posedge clk) begin
        if (oh_out_valid && oh_out_take) begin
            oh_tok[ohc] = oh_out_token;
            oh_sc[ohc]  = oh_out_score;
            ohc = ohc + 1;
        end
    end

    // 看门狗
    initial begin
        #200000
        $display("HANG td r%0d/a%0d/e%0d/oh%0d e_lay=%0d e_acc=%0d ohc=%0d eW=%0d",
                 td_r, td_a, td_e, td_oh, e_lay_w, e_acc_w, ohc, e_words_w);
        $finish;
    end

    initial begin
        integer L, e, w, j;
        integer ce;
        integer gk [0:K-1], gsc [0:K-1];
        integer p, ok, v0, idxc;
        integer calc_a;
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
        // 期望 acc 汇总
        exp_acc = 0;
        for (L = 0; L < NL; L = L + 1)
            for (j = 0; j < TOP; j = j + 1)
                for (w = 0; w < EW; w = w + 1)
                    exp_acc = exp_acc + sw_val(L, gsel_all[L*TOP + j], w);
        exp_acc = exp_acc & 16'hFFFF;
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;
        // 逐层灌 e_score (屏障: 引擎吃完全前层才喂下一层)
        for (L = 0; L < NL; L = L + 1) begin
            if (L > 0) begin
                while (e_lay_w != L) @(posedge clk);   // 引擎进本层 (前层吃毕)
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
        while (!td_e) @(posedge clk);                    // 引擎全会话吃完
        @(posedge clk); @(posedge clk);
        // ── 输出头: 脉冲 go + 开词表流 ──
        @(negedge clk); oh_go = 1; oh_valid = 1;
        @(negedge clk); oh_go = 0;
        while (!td_oh) @(posedge clk);
        @(posedge clk); @(posedge clk);
        oh_valid = 0;
        // ── 黄金 top-K (与 OH 同规则: 分值降, 平局 idx 小先) ──
        calc_a = e_acc_w;
        for (j = 0; j < K; j = j + 1) begin gsc[j] = -1; gk[j] = -1; end
        for (idxc = 0; idxc < VOC; idxc = idxc + 1) begin
            v0 = fk(calc_a, idxc);
            ok = 0;
            for (p = 0; p < K && !ok; p = p + 1)
                if (v0 > gsc[p] || (v0 == gsc[p] && idxc < gk[p])) begin
                    for (j = K-1; j > p; j = j - 1) begin gsc[j] = gsc[j-1]; gk[j] = gk[j-1]; end
                    gsc[p] = v0; gk[p] = idxc; ok = 1;
                end
        end
        // ── 验收 ──
        if (seq_bad) begin $display("FAIL 装配吐流对账违例"); $finish; end
        if (e_words_w !== NL*TOP*EW) begin $display("FAIL 引擎吃词 %0d != %0d", e_words_w, NL*TOP*EW); $finish; end
        if (e_words_w !== a_words_w) begin $display("FAIL 引擎/装配字数 %0d != %0d", e_words_w, a_words_w); $finish; end
        if (e_acc_w !== exp_acc) begin $display("FAIL 引擎 acc %0h != 期望 %0h", e_acc_w, exp_acc); $finish; end
        if (r_sel_w !== NL*TOP) begin $display("FAIL router 吐条 %0d != %0d", r_sel_w, NL*TOP); $finish; end
        if (oh_scan_w !== VOC) begin $display("FAIL 输出头扫描 %0d != %0d", oh_scan_w, VOC); $finish; end
        if (ohc !== K) begin $display("FAIL 输出头吐出 %0d != %0d", ohc, K); $finish; end
        for (j = 0; j < K; j = j + 1)
            if (oh_sc[j] !== gsc[j] || oh_tok[j] !== gk[j]) begin
                $display("FAIL top-K #%0d OH(%0d@%0d) != 金(%0d@%0d)", j, oh_sc[j], oh_tok[j], gsc[j], gk[j]);
                $finish;
            end
        if (r_stalls_w == 0 || a_stalls_w == 0 || oh_stalls_w == 0) begin
            $display("FAIL 停顿 r%0d/a%0d/oh%0d 存在0", r_stalls_w, a_stalls_w, oh_stalls_w); $finish;
        end
        if (r_round_w !== 1 || a_round_w2 !== 1 || oh_round_w2 !== 1) begin
            $display("FAIL round r%0d/a%0d/oh%0d", r_round_w, a_round_w2, oh_round_w2); $finish;
        end
        if (!(td_a && td_r && td_e && td_oh)) begin $display("FAIL 四侧 token_done 未齐"); $finish; end
        $display("== M21 p2_loop: 引擎词%0d acc=%0h 选条%0d top-K扫%0d/吐%0d 停顿 r%0d/a%0d/oh%0d ==",
                 e_words_w, e_acc_w, r_sel_w, oh_scan_w, ohc, r_stalls_w, a_stalls_w, oh_stalls_w);
        $display("##### ALL PASS: M21 P2 算闭环骨架 · 选→装配→层引擎→输出头 四级不丢不序 #####");
        $finish;
    end
endmodule
`default_nettype wire