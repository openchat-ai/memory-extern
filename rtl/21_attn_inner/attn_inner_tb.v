`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// attn_inner_tb.v — attn 头窗内积整链验收 (M6)
//
// 链: 源(组合直出) → attn_window(头窗.读流) → attn_inner_ctl → gemv_array_128
// 每块(一颗头): 8 行 × 点积长 4 (q×S), o[i]=Σ_j q[j]·S[i][j] mod 2^16,
// 行积经阵列 acc 前后差分取回 (阵列无清口)。
// 黄金: S[i][j] = 源字位宽拆解公式值, q 按头公式值 —— 三方核 (差分o / 逐行
// 另算 / 总差分≡末次acc) 全对 ALL PASS。
//────────────────────────────────────────────────────────────────────────────

module attn_inner_tb;
    localparam AW = 8, DW = 32;
    localparam HEADS = 4, HBUF = 16, BUFS = 2, WPR = 2;
    localparam FEED = 2 * WPR;
    localparam ROWS_PB = HBUF / WPR;
    localparam WA = HEADS * BUFS * HBUF;      // 128
    localparam ROWS_TOT = WA / WPR;           // 64

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    //---- 池 + 头窗引擎 (M5 复用) ----
    reg            sel, engine_go, ctl_go;
    wire [DW-1:0]  a_rdata; wire a_rdy;
    wire           s_valid, s_ready;
    wire [DW-1:0]  s_data;
    wire           r_valid; wire [DW-1:0] r_data;
    wire           engine_busy;

    sram_pool_arb #(.AW(AW), .DW(DW)) pool (
        .clk(clk), .rst_n(rst_n), .sel(sel),
        .g_valid(1'b0), .g_we(1'b0), .g_addr(8'd0), .g_wdata(32'd0),
        .g_rdy(), .g_rdata(),
        .a_valid(a_valid), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdy(a_rdy), .a_rdata(a_rdata)
    );
    // (池的 g 侧本幕静默)

    wire a_valid, a_we; wire [AW-1:0] a_addr; wire [DW-1:0] a_wdata;

    attn_window #(.AW(AW), .DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS)) aw (
        .clk(clk), .rst_n(rst_n), .go(engine_go), .busy(engine_busy),
        .a_valid(a_valid), .a_we(a_we), .a_addr(a_addr), .a_wdata(a_wdata),
        .a_rdy(a_rdy), .a_rdata(a_rdata),
        .s_valid(s_valid), .s_data(s_data), .s_ready(s_ready),
        .r_valid(r_valid), .r_take(r_take_c), .r_data(r_data)
    );

    //---- 源: word(全局序K) 组合直出 ----
    // 词 K: 块b=K/16, 块内字w=K%16, 行r=w/2, 半h=w%2;
    // 元素 S(h?,b,r,j) 由 (b,r,j) 公式给出, 词={e(2半+1),e(2半)}
    function [15:0] se(input integer blk, input integer r, input integer j);
        begin
            se = ((blk * 100 + r * 10 + j * 3 + 7) % 254) + 1;
        end
    endfunction

    function [DW-1:0] wordval(input integer K);
        integer blk, w, r, hlf;
        begin
            blk = K / HBUF; w = K % HBUF;
            r = w / WPR; hlf = w % WPR;
            wordval = {se(blk, r, 2*hlf+1), se(blk, r, 2*hlf)};
        end
    endfunction

    assign s_valid = (aw.words_written < WA);
    assign s_data  = wordval(aw.words_written);

    //---- q 模板 (按内积当前块号选头: h = blk/BUFS) ----
    wire [15:0] q_vec [0:FEED-1];
    function [15:0] qf(input integer h, input integer j);
        begin
            qf = ((h * 4 + j) * 7 + 3) % 254 + 1;
        end
    endfunction
    genvar j;
    generate for (j = 0; j < FEED; j = j + 1) begin : QSEL
        assign q_vec[j] = qf((ic.blk_now / BUFS), j);
    end endgenerate

    //---- 内积控制器 ----
    wire ctl_busy;
    wire o_valid, r_take_c;
    wire [15:0] o_data; wire [31:0] o_head, o_row;
    wire [15:0] act_in, weight_in;

    attn_inner_ctl #(.DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS), .WPR(WPR)) ic (
        .clk(clk), .rst_n(rst_n), .go(ctl_go), .busy(ctl_busy),
        .r_valid(r_valid), .r_data(r_data), .r_take(r_take_c),
        .q_vec(q_vec),
        .acc_out_in(acc_out),
        .act_in(act_in), .weight_in(weight_in),
        .o_valid(o_valid), .o_data(o_data), .o_head(o_head), .o_row(o_row),
        .blk_now(),
        .words_rcvd(), .rows_done(), .blocks_done()
    );

    //---- 128-MAC 阵列 ----
    wire [15:0] acc_out;
    wire [7:0]  active_cnt;
    gemv_array_128 #(.MAC_COUNT(128)) u_arr (
        .clk(clk), .rst_n(rst_n),
        .mac_en(128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF),
        .weight_in(weight_in), .act_in(act_in),
        .acc_out(acc_out), .active_cnt(active_cnt)
    );

    //---- 黄金 ----
    integer gold [0:ROWS_TOT-1];

    //---- o 采样对账 (o_head/o_row 直接定序) ----
    integer n_ok = 0;
    reg [31:0] acc_sum = 0;
    always @(posedge clk) begin
        if (ic.o_valid) begin
            if (o_data !== (gold[o_head * ROWS_PB + o_row] & 16'hFFFF)) begin
                $display("%0t FAIL o blk=%0d row=%0d got=%0d gold=%0d",
                         $time, o_head, o_row, o_data,
                         gold[o_head * ROWS_PB + o_row] & 16'hFFFF);
                $fatal;
            end
            n_ok = n_ok + 1;
            acc_sum = (acc_sum + o_data) & 16'hFFFF;
        end
    end

    //---- 看门狗 ----
    integer cycles_busy;
    always @(posedge clk) begin
        if (ic.busy || engine_busy) cycles_busy <= cycles_busy + 1;
        else cycles_busy <= 0;
        if (cycles_busy > 8000) begin
            $display("%0t FAIL watchdog timeout", $time); $fatal;
        end
    end

    //---- 黄金填充 ----
    integer h, b, rr, jj, x;
    initial begin
        for (b = 0; b < HEADS * BUFS; b = b + 1)
            for (rr = 0; rr < ROWS_PB; rr = rr + 1) begin
                h = b / BUFS;
                x = 0;
                for (jj = 0; jj < FEED; jj = jj + 1)
                    x = (x + qf(h, jj) * se(b, rr, jj)) & 16'hFFFF;
                gold[b * ROWS_PB + rr] = x;
            end
    end

    initial begin
        sel = 1; engine_go = 0; ctl_go = 0;
        repeat (3) @(posedge clk); #1; rst_n = 1;
        repeat (3) @(posedge clk);

        //---------- 切权 -> 启动引擎 + 内积 -------
        @(posedge clk); #1; sel = 1;
        @(posedge clk); #1; engine_go = 1;
        @(posedge clk); #1; engine_go = 0;      // session 锁存, 撤 go
        @(posedge clk); #1; ctl_go = 1;
        @(posedge clk); #1; ctl_go = 0;

                while (engine_busy || ctl_busy) begin @(posedge clk); #1; end
        repeat (3) @(posedge clk);            // 沉降: 末行 o 与 busy 同拍, 先等其入账

        //---------- 验收 -------
        if (n_ok != ROWS_TOT) begin
            $display("%0t FAIL o 收数=%0d (期望 %0d)", $time, n_ok, ROWS_TOT); $fatal;
        end
        if (aw.words_written != WA || aw.words_read != WA) begin
            $display("%0t FAIL 头窗 w=%0d r=%0d (期望 %0d)",
                     $time, aw.words_written, aw.words_read, WA); $fatal;
        end
        if (ic.words_rcvd != WA) begin
            $display("%0t FAIL 内积收字=%0d (期望 %0d)", $time, ic.words_rcvd, WA); $fatal;
        end
        if (ic.rows_done != ROWS_TOT || ic.blocks_done != HEADS * BUFS) begin
            $display("%0t FAIL 内积行=%0d 块=%0d (期望 %0d / %0d)",
                     $time, ic.rows_done, ic.blocks_done, ROWS_TOT, HEADS * BUFS); $fatal;
        end
        // 总差分 ≡ 末次 acc (所有行积加总 = 阵列全程累加)
        if (acc_out !== acc_sum[15:0]) begin
            $display("%0t FAIL 总差分 acc_out=%0d 各行和=%0d", $time, acc_out, acc_sum);
            $fatal;
        end

        $display("%0t ================= ALL PASS =================", $time);
        $display("%0t   行数=%0d acc_out=%0d = Σo 对平", $time, n_ok, acc_out);
        $finish;
    end

    initial begin
        #800000;
        $display("%0t FAIL global timeout", $time); $fatal;
    end

    reg [31:0] actr=0;
always @(posedge clk) actr <= actr + 1;

endmodule
`default_nettype wire
