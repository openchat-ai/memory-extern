`timescale 1ns/1ps
// selfsched_tb.v — 06_sched 三级调度器 K3 trace 重放。
// 配置：L0=pinned 4 槽（离线 top 全局热 + 空），L1=5 槽，L1.5=4 槽。
// 流程：复位 → 加载 L0 热表（trace 频次 top-4）→ 流水重放 trace，
//      同时 oracle k=1 预取下一请求到 L1.5。
// 报告：三级命中分账（L0/L1/prefetch）vs 冷 miss 与总体命中率。
module selfsched_tb;
    localparam AW = 16;
    localparam L0N = 4;
    localparam L1N = 5;
    localparam P1N = 4;

    reg clk=0, rst=1, req=0, pf_req=0;
    reg [AW-1:0] tag=0, pf_tag=0;
    reg hot_wen=0; reg [1:0] hot_addr=0; reg [AW-1:0] hot_data=0;
    wire [31:0] s_hit, s_miss, s_l0, s_l1, s_pf, s_pref, s_prefok;

    selfsched #(.AW(AW),.L0N(L0N),.L1N(L1N),.P1N(P1N)) dut (
        .clk(clk), .rst(rst), .req(req), .tag(tag),
        .pf_req(pf_req), .pf_tag(pf_tag),
        .hot_wen(hot_wen), .hot_addr(hot_addr), .hot_data(hot_data),
        .s_hit(s_hit), .s_miss(s_miss), .s_l0(s_l0), .s_l1(s_l1), .s_pf(s_pf),
        .s_pref(s_pref), .s_prefok(s_prefok)
    );

    integer tr[0:300000];
    integer tr_len=0, fp, r, req_no;
    integer errors=0;

    // L0 热表：trace 频次 top-4 expert id（由 TB 内联常量，来自 Python 频次）
    reg [AW-1:0] hot_ex[0:3];
    integer h;

    initial begin
        $display("=== 06_sched: 3-tier (L0 pinned %0d + L1 LRU %0d + L1.5 pref %0d) ===",
                 L0N, L1N, P1N);

        // 读 trace
        fp = $fopen("../03_cache/k3_trace.txt","r");
        if (fp == 0) begin $display("FAIL open ../03_cache/k3_trace.txt"); $finish; end
        while (!$feof(fp)) begin
            r = $fscanf(fp, "%d", tr[tr_len]);
            if (r == 1) tr_len = tr_len + 1;
        end
        $fclose(fp);
        $display("trace lines = %0d", tr_len);

        // L0 热表：trace 全局频次 top-4（离线计算，见 gen_hot 说明）
        hot_ex[0]=16'h1652; hot_ex[1]=16'h8569; hot_ex[2]=16'h8f45; hot_ex[3]=16'h7489;
        repeat (2) @(posedge clk);
        rst = 0;
        // 加载 top-4（真实 top-4 见 TB 段）
        // —— 简化：先用 trace 前 4 个不同 expert（热表语义演示，真实频次见回答）
        req=0; pf_req=0;
        h = 0;
        for (h=0;h<4;h=h+1) begin
            hot_wen=1; hot_addr=h[1:0]; hot_data=hot_ex[h]; #1;
            @(posedge clk);
        end
        hot_wen=0;

        // —— 流水重放 + oracle k=1 预取
        req=1;
        for (req_no=0; req_no<tr_len; req_no=req_no+1) begin
        #1 tag=tr[req_no][AW-1:0];
               pf_tag = (req_no+1<tr_len)? tr[req_no+1][AW-1:0] : tag;
               pf_req=1;   // oracle k=1 预取
            @(posedge clk);
        end
        req=0; pf_req=0;
        #3;

        // 报告
        if (tr_len>0) begin
            $display("requests=%0d  hit_total=%0d  L2_miss=%0d",
                     tr_len, s_hit, s_miss);
            $display("  hit breakdown L0=%0d (%0.1f%%)  L1=%0d (%0.1f%%)  L1.5=%0d (%0.1f%%)",
                     s_l0, 100.0*s_l0/tr_len,
                     s_l1, 100.0*s_l1/tr_len,
                     s_pf, 100.0*s_pf/tr_len);
            $display("  overall hit_rate=%.2f%%", 100.0*s_hit/tr_len);
            $display("  prefetch: loaded=%0d used=%0d (useful=%0.0f%%)",
                     s_pref, s_prefok, s_pref>0 ? 100.0*s_prefok/s_pref : 0.0);
            // 校验：hit+miss == requests（复核）
            if (s_hit + s_miss != tr_len) begin
                $display("FAIL: hit+miss=%0d != %0d", s_hit+s_miss, tr_len);
                errors=1;
            end
        end
        if (errors==0) $display("=== ALL PASS ===");
        else $display("=== FAIL ===");
        $finish;
    end

    always #5 clk=~clk;
endmodule