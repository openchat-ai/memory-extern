`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// router_sel_tb.v — M17 router 先行 top-T 选择件 验收
//
// 链: e_score 流(gate 装载语义) → router_sel(top-T 选择) → 装配侧(out_take)
// 验收(单会话 NL 层):
//   · 灌收序 = 流序 0..EX-1 严格单调 (肇事即罪证)
//   · top-T 表黄金对账: 每行 {idx,score} == 独立排序 top-T (key {score,~idx} 降序,
//     平局 idx 小者先) — 源故意四连同分逼平局断序
//   · 吐表序 = 表序 best-first; 手拉手; 层 barrier 严格累计; round++ 收口
//   · R1 装配侧慢取(1-in-3, 吐期堵) + R2 灌入侧信用断(1-in-3, 吸期背压) ⇒
//     stalls > 0 且各层账分毫不差 (不丢不序不乱)
//────────────────────────────────────────────────────────────────────────────
module router_sel_tb;
    localparam EX = 32, TOP = 8, SW = 16, NL = 3;

    reg clk = 0, rst_n = 0, go = 0;
    always #5 clk = ~clk;

    reg credit = 1, out_take = 1, s_valid = 0;
    wire [SW-1:0] s_score = s_v(curL, u.cur_idx);   // 组合 (派生于 router 自身灌收号)
    wire busy, out_valid, layer_done, token_done;
    wire [$clog2(EX)-1:0] out_idx;
    wire [SW-1:0] out_score;
    wire [7:0] round;
    wire [31:0] layers, selected, stalls;

    router_sel #(.EX(EX), .TOP(TOP), .SW(SW), .NL(NL)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(busy),
        .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_valid(out_valid), .out_idx(out_idx), .out_score(out_score),
        .out_take(out_take),
        .layer_done(layer_done), .token_done(token_done), .round(round),
        .layers(layers), .selected(selected), .stalls(stalls)
    );

    // e_score 源: 值 = L*7 + k/4 (四连同分 → 逼平局断序; 断言键 {score,~idx} 降序)
    function [SW-1:0] s_v(input integer L, input integer k);
        s_v = (L * 7 + k / 4) & 16'hFFFF;
    endfunction

    // 黄金: 独立选择排序取 top-T
    integer g_idx [0:TOP-1];
    integer g_score [0:TOP-1];
    integer doneg [0:EX-1];
    task automatic gold(input integer L);
        integer k, j, bi;
        begin
            for (k = 0; k < EX; k = k + 1) doneg[k] = 0;
            for (j = 0; j < TOP; j = j + 1) begin
                bi = -1;
                for (k = 0; k < EX; k = k + 1)
                    if (!doneg[k])
                        if (bi < 0 ||
                            (s_v(L, k) > s_v(L, bi)) ||
                            (s_v(L, k) == s_v(L, bi) && k < bi)) bi = k;
                doneg[bi] = 1;
                g_idx[j] = bi; g_score[j] = s_v(L, bi);
            end
        end
    endtask

    // 记录(单块, 无跨块次序): 逐行 {idx,score} + 灌序 + 层/token 计数
    integer rows [0:NL-1][0:TOP-1], rowc [0:NL-1];
    integer curL = 0, ld_ct = 0, td_seen = 0, seq_bad = 0;
    integer src_idx = 0;
    reg ld_d1 = 0, td_d1 = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            curL = 0; ld_ct = 0; td_seen = 0; seq_bad = 0; src_idx = 0;
            ld_d1 <= 0; td_d1 <= 0;
            for (integer a = 0; a < NL; a = a + 1) rowc[a] = 0;
            for (integer a = 0; a < NL; a = a + 1)
                for (integer b = 0; b < TOP; b = b + 1) rows[a][b] = 0;
        end else begin
            if (out_valid && out_take && curL < NL && rowc[curL] < TOP) begin
                rows[curL][rowc[curL]] = out_idx * 65536 + out_score;
                rowc[curL] = rowc[curL] + 1;
            end
            if (s_valid && credit && busy && src_idx < EX) begin
                if (src_idx != curL_acc)
                    seq_bad = 1;
                src_idx = src_idx + 1;
                curL_acc = curL_acc + 1;
            end
            ld_d1 <= layer_done; td_d1 <= token_done;
            if (layer_done && !ld_d1) begin
                ld_ct = ld_ct + 1;
                curL = curL + 1;
                src_idx = 0; curL_acc = 0;
            end
            if (token_done && !td_d1) td_seen = 1;
        end
    integer curL_acc = 0;

    // 源: 始终想发 (堵/断记到 router 自己)
    always @(posedge clk or negedge rst_n)
        if (!rst_n) s_valid <= 0;
        else begin
            s_valid <= 1;
        end

    // 周期计数 (R1/R2 变速相位)
    reg [31:0] ck = 0;
    always @(posedge clk) ck <= ck + 1;

    // 看门狗
    integer wdc = 0;
    always @(posedge clk)
        if (busy) begin
            if (wdc > 50000) begin $display("%0t FAIL watchdog", $time); $finish; end
            wdc = wdc + 1;
        end else wdc = 0;

    integer e, b;
    task automatic check_layer(input integer Lc, input [8*9:0] tag);
        integer sum;
        begin
            e = 0; sum = 0;
            gold(Lc);
            for (b = 0; b < TOP; b = b + 1) begin
                if (rows[Lc][b] != g_idx[b] * 65536 + g_score[b]) e = 1;
                sum = sum + g_score[b];
            end
            if (rowc[Lc] != TOP) e = 1;
            if (e == 0)
                $display("== %s L%0d top%0d 序%0d 全对账 (sum=%0d) ✓", tag, Lc, TOP,
                         g_idx[0], sum);
            else begin
                $display("FAIL %s L%0d:", tag, Lc);
                for (b = 0; b < TOP; b = b + 1)
                    $display("   row%0d got idx%0d=%0d gold idx%0d=%0d", b,
                             rows[Lc][b] / 65536, rows[Lc][b] % 65536,
                             g_idx[b], g_score[b]);
                $finish;
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;
        @(posedge clk); go = 1; @(posedge clk); go = 0;

        // R0: L0 全速
        while (ld_ct < 1) @(posedge clk);
        // R1: L1 装配侧慢取 1-in-3 (吐期堵)
        while (ld_ct < 2) begin
            out_take = (ck[0] == 1'b0) ? 1'b1 : 1'b0;   // 1-in-2 (强化堵幅)
            @(posedge clk);
        end
        out_take = 1;
        // R2: L2 灌入侧信用断 1-in-2 (吸期背压)
        while (!td_seen) begin
            credit = (ck[0] == 1'b0) ? 1'b1 : 1'b0;
            @(posedge clk);
        end
        credit = 1;
        repeat (12) @(posedge clk);

        check_layer(0, "R0"); check_layer(1, "R1"); check_layer(2, "R2");

        if (ld_ct != NL || td_seen != 1 || round != 1) begin
            $display("FAIL 层%0d/%0d token%0d round%0d", ld_ct, NL, td_seen, round);
            $finish;
        end
        if (u.selected != NL * TOP) begin
            $display("FAIL selected %0d/%0d", u.selected, NL * TOP); $finish;
        end
        if (u.stalls == 0) begin
            $display("%0t FAIL stalls %0d (应>0: R1 吐期/R2 吸期背压)", $time, u.stalls); $finish;
        end
        if (seq_bad) begin $display("FAIL 灌收序违例"); $finish; end

        $display("== router: 层%0d token%0d round%0d 吐条%0d 停顿%0d 序违例%0d ==",
                 u.layers, td_seen, round, u.selected, u.stalls, seq_bad);
        $display("##### ALL PASS: M17 router 先行 top-%0d 选择 · 平局idx小先 · 双向背压 · 层barrier #####", TOP);
        $finish;
    end

    initial begin #5000000; $display("M17 FAIL timeout"); $finish; end
endmodule
`default_nettype wire