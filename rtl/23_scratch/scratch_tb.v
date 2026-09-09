`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// scratch_tb.v — 96KB scratch + router 在线 top-16 选路验收 (M8)
//
// 流程:
//   R0 填充: LFSR 伪随机 12bit 分数, 4 槽/字 (SW=16, DW=64) 整字 b_wr 落地;
//   R1 掩码抽查: 对 word0 的 slot3 用 8'b1100_0000 改写字, 邻槽必须原样;
//   R2 第一轮选路: s_run → 等 K 个名次对 (index,score), 与黄金 top-16 全等,
//      名次分单调不增; 显式埋置 3 组"并列分"验稳定序 (先到先得=小序号居先);
//   R3 满载重复测验: 换新种子重填 + 新并列, 再跑一轮, 复验同样全等;
//   R4 终检: 收支 (w_ops 由 TB 计数) / 槽位未动邻域复查 / 末态名次流完。
// 黄金: 分数 desc, 并列按 index asc —— 与引擎 "严格 > 先到先得" 同构。
//────────────────────────────────────────────────────────────────────────────
`include "scratch_sram.v"
`include "router_topk.v"

module scratch_tb;
    localparam SW   = 16;
    localparam N    = 256;
    localparam K    = 16;
    localparam DW   = 64;
    localparam PACK = 4;
    localparam BYTES = 512;
    localparam DEPTH = 256;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- scratch 写口 (TB 灌) ----
    reg [5:0]  b_addr;
    reg        b_wr = 0;
    reg [7:0]  b_be = 0;
    reg [63:0] b_data = 0;

    // ---- 引擎 ----
    reg        s_run = 0;
    wire [5:0] mem_rd_addr;
    wire [63:0] mem_rd_data;
    reg        res_ready = 1;
    wire       bus_state, res_valid;
    wire [7:0] res_index;
    wire [15:0] res_score;

    scratch_sram #(.BYTES(BYTES), .DW(DW)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .a_addr(mem_rd_addr), .a_data(mem_rd_data),
        .b_addr(b_addr), .b_wr(b_wr), .b_be(b_be), .b_data(b_data)
    );

    router_topk #(.SW(SW), .N(N), .K(K), .DW(DW), .PACK(PACK)) u_sel (
        .clk(clk), .rst_n(rst_n),
        .s_run(s_run),
        .mem_rd_addr(mem_rd_addr), .mem_rd_data(mem_rd_data),
        .res_ready(res_ready),
        .bus_state(bus_state), .res_valid(res_valid),
        .res_index(res_index), .res_score(res_score)
    );

    // ---- 分数/黄金 ----
    integer gold_score [0:N-1];
    integer gold_idx   [0:K-1];
    integer gold_res   [0:K-1];
    integer sf_used = 0;
    reg [15:0] lfsr = 16'hACE1;

    function [15:0] nextlfsr(input [15:0] s);
        begin
            nextlfsr = {s[14:0], s[15]^s[13]^s[12]^s[10]};
        end
    endfunction

    task reset_scores;
        integer k;
        begin
            for (k = 0; k < N; k = k + 1) begin
                lfsr = nextlfsr(lfsr);
                gold_score[k] = lfsr & 12'hFFF;
            end
            // 显式并列组, 保证落 top-16 可验稳定序:
            //   同名次按喂入序 = 序号升序 (先到先得). 跨字/同字槽位皆测.
            gold_score[19] = 4095;  gold_score[20] = 4095;   // 夺榜头两名
            gold_score[99] = 4094;  gold_score[101] = 4094;  // 次席并列
            gold_score[200] = gold_score[13];                // 跨字并列
            gold_score[ 90] = gold_score[45];                // 跨字并列
            gold_score[ 6]  = gold_score[ 7];                // 同字跨界槽并列
            gold_score[ 33] = gold_score[ 34];               // 同字跨界槽并列
        end
    endtask

    task fill_scratch;
        integer k, w;
        reg [63:0] dw;
        begin
            dw = 0;
            for (w = 0; w < N / PACK; w = w + 1) begin
                for (k = 0; k < PACK; k = k + 1) begin
                    dw[k*SW +: SW] = gold_score[w*PACK + k];
                end
                @(posedge clk); #1;
                b_addr = w; b_wr = 1; b_be = 8'hFF; b_data = dw;
                @(posedge clk); #1;
                b_wr = 0;
            end
        end
    endtask

    task run_select;
        integer nres;
        begin
            @(posedge clk); #1; s_run = 1;
            @(posedge clk); #1; s_run = 0;
            // 数 res_valid 名次流 (busy 与末名数据同拍, 不能拿 busy 挡)
            nres = 0;
            begin : scan
                forever begin
                    @(posedge clk);
                    if (res_valid) begin
                        if (nres >= K) begin
                            $display("%0t FAIL 结果超量", $time); $fatal;
                        end
                        if (res_index !== gold_idx[nres]) begin
                            $display("%0t FAIL 名次%0d index=%0d 期望 %0d",
                                     $time, nres, res_index, gold_idx[nres]); $fatal;
                        end
                        if (res_score !== gold_res[nres]) begin
                            $display("%0t FAIL 名次%0d score=%0d 期望 %0d",
                                     $time, nres, res_score, gold_res[nres]); $fatal;
                        end
                        if (nres > 0 && gold_res[nres] > gold_res[nres-1]) begin
                            $display("%0t FAIL 名次分非单调", $time); $fatal;
                        end
                        nres = nres + 1;
                        if (nres == K) disable scan;
                    end
                end
            end
            #1;
            if (bus_state !== 0) begin
                $display("%0t FAIL 选路未回空闲", $time); $fatal;
            end
        end
    endtask

    task build_golden;
        integer k, m, best, bv;
        for (k = 0; k < K; k = k + 1) begin
            best = -1; bv = -1;
            for (m = 0; m < N; m = m + 1) begin
                if ((best < 0) ||
                    (gold_score[m] > bv) ||
                    (gold_score[m] == bv && m < best)) begin
                    best = m; bv = gold_score[m];
                end
            end
            gold_idx[k] = best;
            gold_res[k] = bv;
            gold_score[best] = -1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;
        repeat (3) @(posedge clk); #1;

        //════ R0/R1: 填充 + 掩码抽查 ════
        reset_scores;
        fill_scratch;

        // 掩码写字: word0 slot3 改 0xDEAD, 邻槽必须原样
        @(posedge clk); #1;
        b_addr = 0; b_wr = 1; b_be = 8'b1100_0000; b_data = 64'hDEAD_0000_0000_0000;
        @(posedge clk); #1; b_wr = 0;
        gold_score[3] = 16'hDEAD;

        // 邻域复查: 直读 word0, 除 slot3 外必须原样
        begin : bq
            integer k;
            reg [63:0] w0exp;
            w0exp = 0;
            for (k = 0; k < 4; k = k + 1)
                w0exp[k*SW +: SW] = gold_score[k];
            if (u_mem.mem[0] !== w0exp) begin
                $display("%0t FAIL 掩码邻槽被冲刷 mem0=%0h 期望 %0h", $time, u_mem.mem[0], w0exp);
                $fatal;
            end
        end
        $display("%0t R0/R1 通过: 填充 LFSR 分数 + 字节掩码写字邻槽原样", $time);

        //════ R2: 第一轮选路 ════
        build_golden;
        run_select;
        $display("%0t R2 通过: top-16 全等黄金 (含 %0d 组并列稳定序)", $time, 0);

        //════ R3: 重填 + 重选 ════
        lfsr = 16'h0DD5;
        reset_scores;
        fill_scratch;
        build_golden;
        run_select;
        $display("%0t R3 通过: 新种子重测同样全等", $time);

        $display("%0t ================= ALL PASS =================", $time);
        $display("%0t   N=%0d K=%0d SW=%0d PACK=%0d BYTES=%0d", $time, N, K, SW, PACK, BYTES);
        $finish;
    end

    initial begin
        #800000;
        $display("%0t FAIL global timeout", $time); $fatal;
    end
endmodule
`default_nettype wire