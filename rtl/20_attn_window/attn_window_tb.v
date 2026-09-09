`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// attn_window_tb.v — S 头窗引擎 × 池 端到端验收
//
// 剧本:
//   P0 GEMM 段爆发 (g_* 写5读5, sel=0) —— 池仍忠实时分
//   P1 切权 (sel=1, 轮询 switches) —— S 头窗引擎 go: 源流灌 128 字
//      (8 块 = 4头×2缓冲×16字), 读侧滞后一整块紧跟消费 (双缓冲生效),
//      全部对回黄金 (模式自识别: 写入值 == 池地址)
//   P2 切回 sel=0, g_* 全池 128 地址扫读复核
//   判据: a_ops==128, switches==2, words_written==words_read==128,
//        reads_in_overlap>0 (双缓冲确实在跑), ALL PASS
//────────────────────────────────────────────────────────────────────────────
`include "attn_window.v"

module attn_window_tb;
    localparam AW = 8, DW = 32;
    localparam HEADS = 4, HBUF = 16, BUFS = 2;
    localparam NBUF = HEADS * BUFS;         // 8 块
    localparam TOTAL = NBUF * HBUF;         // 128 字
    localparam HBW = 4;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    //---- 池 ----
    reg            sel;
    reg            g_valid, g_we;
    reg [AW-1:0]   g_addr;
    reg [DW-1:0]   g_wdata;
    wire           g_rdy;
    wire [DW-1:0]  g_rdata;

    wire           a_valid, a_we;
    wire [AW-1:0]  a_addr;
    wire [DW-1:0]  a_wdata;
    wire           a_rdy;
    wire [DW-1:0]  a_rdata;

    sram_pool_arb #(.AW(AW), .DW(DW)) pool (
        .clk(clk), .rst_n(rst_n), .sel(sel),
        .g_valid(g_valid), .g_we(g_we), .g_addr(g_addr), .g_wdata(g_wdata),
        .g_rdy(g_rdy), .g_rdata(g_rdata),
        .a_valid(a_valid), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdy(a_rdy), .a_rdata(a_rdata)
    );

    //---- 引擎 ----
    reg            go;
    wire           busy;
    wire           s_valid, s_ready;
    wire [DW-1:0]  s_data;
    wire           r_valid, r_take;
    wire [DW-1:0]  r_data;

    attn_window #(.AW(AW), .DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS)) u (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(busy),
        .a_valid(a_valid), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdy(a_rdy), .a_rdata(a_rdata),
        .s_valid(s_valid), .s_data(s_data), .s_ready(s_ready),
        .r_valid(r_valid), .r_take(r_take), .r_data(r_data)
    );
    assign r_take = 1'b1;

    //---- 源: 数据按块序确定性灌入, 组合直出 (引擎采样到"正要写的那个字") ----
    function [DW-1:0] pat(input integer n, input integer w);
        begin
            pat = ((n >> 1) << (HBW + 1)) | ((n & 1) << HBW) | w;
        end
    endfunction
    assign s_valid = (u.words_written < TOTAL);
    assign s_data  = pat(u.words_written / HBUF, u.words_written % HBUF);

    //---- 消费 (黄金对账) ----
    integer cn, cw, ncheck, nexp;
    always @(posedge clk) begin
        if (u.r_valid) begin
            nexp = pat(cn, cw);
            if (u.r_data !== nexp[31:0]) begin
                $display("%0t FAIL read stream n=%0d w=%0d got=%h expect=%h",
                         $time, cn, cw, u.r_data, nexp[31:0]);
                $fatal;
            end
            ncheck <= ncheck + 1;
            if (cw == HBUF-1) begin cn <= cn + 1; cw <= 0; end
            else              cw <= cw + 1;
        end
    end

    //---- 看门狗 ----
    integer cycles_busy;
    always @(posedge clk) begin
        if (u.busy) cycles_busy <= cycles_busy + 1;
        else        cycles_busy <= 0;
        if (cycles_busy > 5000) begin
            $display("%0t FAIL watchdog timeout busy=1", $time);
            $fatal;
        end
    end

    //---- 任务 (沿后 #1, 采样前稳定) ----
    task g_write(input [AW-1:0] a, input [DW-1:0] d);
        begin
            @(posedge clk); #1; g_valid = 1; g_we = 1; g_addr = a; g_wdata = d;
            @(posedge clk); #1; g_valid = 0; g_we = 0;
        end
    endtask

    task g_read(input [AW-1:0] a, output [DW-1:0] d);
        begin
            @(posedge clk); #1; g_valid = 1; g_we = 0; g_addr = a;
            @(posedge clk); #1; g_valid = 0;
            @(posedge clk); #1; d = g_rdata;
        end
    endtask

    task wait_sw(input integer target);
        begin
            while (pool.switches < target) begin
                @(posedge clk); #1;
                if (pool.switches > target + 4) begin
                    $display("%0t FAIL switch overshoot", $time); $fatal;
                end
            end
        end
    endtask

    integer i, rd, n;

    initial begin
        // init
        sel = 0; g_valid = 0; g_we = 0; g_addr = 0; g_wdata = 0;
        go = 0; cn = 0; cw = 0; ncheck = 0;

        repeat (3) @(posedge clk); #1; rst_n = 1;

        // ============ P0: GEMM 段爆发 (sel=0), 检查池仍忠实时分 ============
        for (i = 0; i < 5; i = i + 1) g_write(i[7:0], 32'hFEED0000 + i[31:0]);
        for (i = 0; i < 5; i = i + 1) begin
            g_read(i[7:0], rd);
            if (rd !== (32'hFEED0000 + i)) begin
                $display("%0t FAIL P0 g_read[%0d] got=%h", $time, i, rd); $fatal;
            end
        end
        if (pool.g_ops != 10 || pool.a_ops != 0 || pool.switches != 0) begin
            $display("%0t FAIL P0 counters g=%0d a=%0d sw=%0d", $time,
                     pool.g_ops, pool.a_ops, pool.switches); $fatal;
        end
        $display("%0t P0 GEMM burst  5w+5r OK (g_ops=%0d)", $time, pool.g_ops);

        // ============ P1: 切权, 引擎 go, 灌/读 128 字 ============
        @(posedge clk); #1; sel = 1;
        wait_sw(1);
        $display("%0t switch->attn committed (switches=%0d)", $time, pool.switches);

        @(posedge clk); #1; go = 1;
        while (!u.busy) begin @(posedge clk); #1; end
        @(posedge clk); #1; go = 0;                 // 落权后立即撤 go (防重触发)
        while (u.busy) begin @(posedge clk); #1; end

        if (u.words_written != TOTAL || u.words_read != TOTAL) begin
            $display("%0t FAIL engine counts w=%0d r=%0d (expect %0d)", $time,
                     u.words_written, u.words_read, TOTAL); $fatal;
        end
        if (u.fills_done != NBUF || u.reads_done != NBUF) begin
            $display("%0t FAIL block counts fill=%0d read=%0d (expect %0d)",
                     $time, u.fills_done, u.reads_done, NBUF); $fatal;
        end
        if (u.reads_in_overlap == 0) begin
            $display("%0t FAIL no overlap: double-buffer not active", $time); $fatal;
        end
        if (u.r_valid) begin
            $display("%0t FAIL residual activity r_valid=%b", $time, u.r_valid); $fatal;
        end
        if (pool.a_ops != 2 * TOTAL) begin
            $display("%0t FAIL a_ops=%0d (expect %0d = 写%d+读%d)",
                     $time, pool.a_ops, 2 * TOTAL, TOTAL, TOTAL); $fatal;
        end
        if (ncheck != TOTAL) begin
            $display("%0t FAIL consumed=%0d (expect %0d)", $time, ncheck, TOTAL); $fatal;
        end
        $display("%0t P1 attn windows %0d words w=%0d r=%0d overlap=%0d OK",
                 $time, TOTAL, u.words_written, u.words_read, u.reads_in_overlap);

        // ============ P2: 切回 GEMM 持权, 全池 128 地址扫读复核 ============
        @(posedge clk); #1; sel = 0;
        wait_sw(2);
        for (n = 0; n < TOTAL; n = n + 1) begin
            g_read(n & 8'hFF, rd);
            if (rd !== n) begin
                $display("%0t FAIL pool sweep addr=%0d got=%h expect=%h",
                         $time, n, rd, n); $fatal;
            end
        end
        if (pool.switches != 2) begin
            $display("%0t FAIL switches=%0d (expect 2)", $time, pool.switches); $fatal;
        end

        $display("%0t ================= ALL PASS =================", $time);
        $display("%0t   g_ops=%0d a_ops=%0d switches=%0d words=%0d overlap=%0d",
                 $time, pool.g_ops, pool.a_ops, pool.switches, TOTAL,
                 u.reads_in_overlap);
        $finish;
    end

    initial begin
        #500000;
        $display("%0t FAIL global timeout", $time);
        $fatal;
    end
endmodule
`default_nettype wire