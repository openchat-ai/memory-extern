`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// output_head_tb.v — M19 输出头件验收
//
// 场景: 会话 TN=3 token, 每 token 扫 VOC=32 logits 流取 top-K=3 (值域 %23 逼平局,
//       stable 平局 idx 小者先)。背压练习:
//   t0  全速
//   t1  扫描期断流 5 拍 (in_valid=0 → 扫描静待, 停拍记 stall)
//   t2  吐期 out_take 1-in-2 (下游慢取, 停拍记 stall)
// 对账: 每 token 吐流的 top-K (下标+分值) == 黄金 (独立全排序); 全程无错位/无重
//       号; scanned == TN*VOC; 吐 K*TN; token_done 后 round==1。
//────────────────────────────────────────────────────────────────────────────
module output_head_tb;
    localparam TN = 3, VOC = 32, K = 3, BB = 16;

    reg clk = 1, rst_n = 0, go = 0;
    reg in_valid = 0;
    reg [BB-1:0] in_logit = 0;
    wire in_take;
    reg out_take = 1;
    wire out_valid;
    wire [BB-1:0] out_score;
    wire [$clog2(VOC)-1:0] out_token;
    wire token_done;
    wire [$clog2(TN)-1:0] tok_w;
    wire [5:0] round_w;
    wire [31:0] stalls_w, scanned_w;

    output_head #(.TN(TN), .VOC(VOC), .K(K), .BB(BB)) u(
        .clk(clk), .rst_n(rst_n), .go(go),
        .in_valid(in_valid), .in_logit(in_logit), .in_take(in_take),
        .out_valid(out_valid), .out_score(out_score), .out_token(out_token), .out_take(out_take),
        .scan_end(se_c),
        .token_done(token_done),
        .tok_idx(tok_w), .round(round_w), .stalls(stalls_w), .scanned(scanned_w)
    );
    wire [$clog2(VOC)-1:0] se_c = VOC - 1;

    always #5 clk = ~clk;

    // ── logits (值域逼平局) ──
    function integer fv(input integer t, input integer k);
        fv = (k*17 + t*7) % 23;
    endfunction

    // ── 黄金: 每 token top-K (平局 stable idx 小者先) ──
    integer gtok [0:TN*K-1];
    integer gscr [0:TN*K-1];
    task automatic gold_all();
        integer t, r, k, bi;
        integer donev [0:VOC-1];
        for (t = 0; t < TN; t = t + 1) begin
            for (k = 0; k < VOC; k = k + 1) donev[k] = 0;
            for (r = 0; r < K; r = r + 1) begin
                bi = -1;
                for (k = 0; k < VOC; k = k + 1)
                    if (!donev[k])
                        if (bi < 0 ||
                            (fv(t, k) > fv(t, bi)) ||
                            (fv(t, k) == fv(t, bi) && k < bi)) bi = k;
                donev[bi] = 1;
                gtok[t*K + r] = bi;
                gscr[t*K + r] = fv(t, bi);
            end
        end
    endtask

    // ── 吐流对账 monitor ──
    integer emc = 0, ge = 0, ecur = -1;
    reg seq_bad = 0, tok_seen = 0;
    always @(posedge clk) begin
        if (ecur != tok_w) begin emc = 0; ecur = tok_w; end
        if (out_valid && out_take) begin
            if (out_token !== gtok[ecur*K + emc])
                seq_bad = 1;
            if (out_score !== gscr[ecur*K + emc])
                seq_bad = 1;
            emc = emc + 1;
            ge = ge + 1;
        end
        if (token_done) tok_seen = 1;
    end

    // ── t2 吐期 1-in-2 慢取 ──
    reg [3:0] tgen = 0;
    always @(posedge clk) tgen <= tgen + 1;
    always @(negedge clk) begin
        if ((tok_w == 2) && out_valid) out_take = tgen[0];
        else out_take = 1;
    end

    // 看门狗: 卡住定位阶段
    initial begin
        #80000
        $display("HANG tok=%0d st=%0d in_v=%0d in_t=%0d out_v=%0d out_t=%0d scanned=%0d",
                 u.tok_idx, u.st, in_valid, in_take, out_valid, out_take, u.scanned);
        $finish;
    end

    initial begin
        integer t, k;
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        gold_all();
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;
        // 逐 token 推 logits 流
        for (t = 0; t < TN; t = t + 1) begin
            for (k = 0; k < VOC; k = k + 1) begin
                @(negedge clk);
                in_valid = 0;
                in_logit = fv(t, k);
                if (t == 1 && k == 16) begin             // t1 扫描期断流 5 拍
                    repeat (5) @(negedge clk);
                end
                in_valid = 1;
                while (!in_take) @(posedge clk);          // 被取走为止 (自然对齐 S_SCAN)
            end
            @(negedge clk);
            in_valid = 0;
        end
        while (!tok_seen) @(posedge clk);
        @(posedge clk);
        @(posedge clk);
        // ── 验收 ──
        if (seq_bad) begin
            $display("FAIL top-K 对账违例"); $finish;
        end
        if (scanned_w !== TN*VOC) begin
            $display("FAIL 扫描数 %0d != %0d", scanned_w, TN*VOC); $finish;
        end
        if (ge !== TN*K) begin
            $display("FAIL 吐数 %0d != %0d", ge, TN*K); $finish;
        end
        if (stalls_w == 0) begin
            $display("FAIL 无停顿(未碰到背压)"); $finish;
        end
        if (round_w !== 1) begin
            $display("FAIL round=%0d", round_w); $finish;
        end
        if (tok_w !== TN-1) begin
            $display("FAIL tok_idx=%0d", tok_w); $finish;
        end
        $display("== M19 output_head: token%0d round=%0d 扫%0d 吐%0d 停顿%0d 序违例%0d ==",
                 tok_w, round_w, scanned_w, ge, stalls_w, seq_bad);
        $display("##### ALL PASS: M19 输出头 · 每词扫全词表取 top-K · 平局stable · 扫描断流+吐期慢取不丢不序 #####");
        $finish;
    end
endmodule
`default_nettype wire