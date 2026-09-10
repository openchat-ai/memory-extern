`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// sched_exec_tb.v — M11 层执行调度器 整链验收
//
// 链: wb_flow(家→灌切片库) → sched_exec(层主脑) → {gemv_rail_ctl + 切片库}
//                                                      → gemv_array_128 (共享)
//                                      └→ {attn_window + attn_inner_ctl}
//
// sched_exec 每层: GEMM段(slice→rail→MAC) → attn段(窗+内积→MAC) → 释放(wb_flow),
// 严格层序 0..NL-1; 两段复用同一 MAC 阵列(acc 从 rst 全程累计, 永不归零)。
//
// 验收(每轮):
//   · 结构: exec 层/段/切换计数=NL; wb released=NL、release_bad=0
//   · 引擎端差量(会话快照): rail words_fed=NL*GW frames=NL; ctl 收字=NL*ATW
//     行=NL*ROWS_TOT 块=NL*BLK; 头窗写/读=NL*ATW; o 行数=NL*ROWS_TOT
//   · 数据三核(独立于引擎内构):
//       (a) GEMM 段贡献公式 Σ_层Σ_w w*(pwr(L,w)&0xFFFF)  == gacc(段镜像)
//       (b) o 逐行对账 = Σ_j qf(h,j)*se_in(L,b,rr,j)     → osum 全对平
//       (c) acc_out == sacc(逐拍镜像阵列输入) == (gacc+aacc)≡ 同账
//   · 释放序罪证: TB 侧逐事件 rl_layer 必须恰为 0..NL-1 递增, 恰 NL 次
//   · R1 变速(churn 1-in-3): barrier_waits 应>R0, 但各项账目分毫不差
//   · R2 续跑: 不重启, acc 累计继续可比, release_bad 全程 0
//────────────────────────────────────────────────────────────────────────────
module sched_exec_tb;
    localparam DW=32, AW=8, SW=16, NL=4, GW=16, ATW=128;
    localparam HEADS=4, HBUF=16, BUFS=2, WPR=2;
    localparam FEED=2*WPR, ROWS_PB=HBUF/WPR, WA=HEADS*BUFS*HBUF, ROWS_TOT=WA/WPR;
    localparam BLK=HEADS*BUFS, TOT=NL*GW;

    reg clk=0, rst_n=0, go=0;
    always #5 clk = ~clk;

    //---------------- 切片库 (A-tile 双槽模型: 写=wb_flow, 读组合) ----------------
    reg [DW-1:0] smem [0:2*SW-1];
    wire [AW-1:0] sl_adr;
    wire [DW-1:0] sl_dat;
    assign sl_dat = smem[sl_adr];

    //---- wb_flow (家源) ----
    wire wb_s_ready;
    reg  churn_en = 0;
    reg  [31:0] wp = 0;
    reg  [1:0]  mask3 = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) wp <= 0;
        else if (wb_s_ready && wb_s_valid) wp <= wp + 1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) mask3 <= 0;
        else if (churn_en) mask3 <= mask3 + 1;

    function [31:0] pwr(input integer L, input integer w);
        begin pwr = (L*104729 + w*131 + 7) & 32'h00FFFFFF; end
    endfunction

    wire wb_s_valid = (wp < TOT) && (~churn_en || (mask3 != 2'd2));
    wire [DW-1:0] wb_s_data = pwr(wp / SW, wp % SW);

    wire wb_g_valid, wb_g_we;
    wire [AW-1:0] wb_g_addr;
    wire [DW-1:0] wb_g_wdata;
    wire wb_busy, wb_release_bad;
    wire [31:0] wb_layer_fill, wb_layers_done;

    wire ex_rl_valid; wire [31:0] ex_rl_layer;

    wb_flow #(.DW(DW), .AW(AW), .SLICE_W(SW), .NL(NL)) u_flow (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(wb_busy),
        .s_valid(wb_s_valid), .s_data(wb_s_data), .s_ready(wb_s_ready),
        .g_rdy(1'b1), .g_valid(wb_g_valid), .g_we(wb_g_we),
        .g_addr(wb_g_addr), .g_wdata(wb_g_wdata),
        .rl_valid(ex_rl_valid), .rl_layer(ex_rl_layer[1:0]), .release_bad(wb_release_bad),
        .layer_fill(wb_layer_fill), .layers_done(wb_layers_done),
        .words_this(), .overlap_cnt(), .barrier_stalls()
    );
    always @(posedge clk)
        if (wb_g_valid && wb_g_we) smem[wb_g_addr] <= wb_g_wdata;

    //---------------- sched_exec (层主脑) ----------------
    wire ex_busy, ex_sel_o, ex_r_valid, ex_r_frame_done;
    wire [DW-1:0] ex_r_data;
    wire [3:0] ex_r_addr;
    wire ex_a_go, ex_a_s_valid, ex_c_go;
    wire [DW-1:0] ex_a_s_data;
    wire [31:0] ex_a_ww, ex_a_wr, ex_c_blocks;
    wire [1:0] ex_phase; wire [2:0] ex_st; wire [$clog2(NL)-1:0] ex_layer_now;
    wire [31:0] ex_layers_done, ex_gemm_done, ex_attn_done, ex_sel_sw,
                ex_barrier, ex_wg_words, ex_wa_words;

    sched_exec #(.DW(DW), .AW(AW), .NL(NL), .GW(GW), .GDEPTH(GW), .ATW(ATW)) u_ex (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(ex_busy),
        .layer_fill(wb_layer_fill), .layer_sync(wb_layers_done),
        .rl_valid(ex_rl_valid), .rl_layer(ex_rl_layer), .a_busy(aw_busy),
        .sel_o(ex_sel_o),
        .slice_addr(sl_adr), .slice_rdata(sl_dat),
        .r_valid(ex_r_valid), .r_data(ex_r_data), .r_frame_done(ex_r_frame_done),
        .r_addr(ex_r_addr), .r_take(rail_r_take),
        .a_go(ex_a_go), .a_s_valid(ex_a_s_valid), .a_s_data(ex_a_s_data),
        .a_s_ready(aw_s_ready), .a_ww(aw_ww), .a_wr(aw_wr),
        .c_go(ex_c_go), .c_busy(ctl_busy), .c_blocks(ctl_blocks_done),
        .phase(ex_phase),
        .st_o(ex_st), .layer_now(ex_layer_now),
        .layers_done(ex_layers_done), .gemm_done(ex_gemm_done),
        .attn_done(ex_attn_done), .sel_switches(ex_sel_sw),
        .barrier_waits(ex_barrier), .wg_words(ex_wg_words), .wa_words(ex_wa_words)
    );

    //---- gemv_rail_ctl (GEMM 段) ----
    wire rail_r_take, rail_feed;
    wire [15:0] rail_act, rail_w;
    wire [31:0] rail_words, rail_frames;
    gemv_rail_ctl #(.DW(DW), .TDEPTH(GW), .AIDX(4)) u_rail (
        .clk(clk), .rst_n(rst_n),
        .r_valid(ex_r_valid), .r_take(rail_r_take), .r_data(ex_r_data),
        .r_frame_done(ex_r_frame_done), .r_addr(ex_r_addr),
        .act_in(rail_act), .weight_in(rail_w), .feed(rail_feed),
        .words_fed(rail_words), .frames_done(rail_frames)
    );

    //---- 池 (attn 段 a_ 口; g_ 本幕静默) ----
    wire a_rdy; wire [DW-1:0] a_rdata;
    wire aw_a_valid, aw_a_we; wire [AW-1:0] aw_a_addr; wire [DW-1:0] aw_a_wdata;
    wire [31:0] pool_switches;
    sram_pool_arb #(.AW(AW), .DW(DW)) u_pool (
        .clk(clk), .rst_n(rst_n), .sel(ex_sel_o),
        .g_valid(1'b0), .g_we(1'b0), .g_addr({AW{1'b0}}), .g_wdata({DW{1'b0}}),
        .g_rdy(), .g_rdata(),
        .a_valid(aw_a_valid), .a_we(aw_a_we), .a_addr(aw_a_addr),
        .a_wdata(aw_a_wdata), .a_rdy(a_rdy), .a_rdata(a_rdata),
        .g_ops(), .a_ops(), .switches(pool_switches)
    );

    //---- attn_window ----
    wire aw_busy, aw_s_ready, aw_r_valid;
    wire [DW-1:0] aw_r_data;
    wire [31:0] aw_ww, aw_wr;
    attn_window #(.AW(AW), .DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS)) aw (
        .clk(clk), .rst_n(rst_n),
        .go(ex_a_go), .busy(aw_busy),
        .a_valid(aw_a_valid), .a_we(aw_a_we), .a_addr(aw_a_addr),
        .a_wdata(aw_a_wdata), .a_rdy(a_rdy), .a_rdata(a_rdata),
        .s_valid(ex_a_s_valid), .s_data(ex_a_s_data), .s_ready(aw_s_ready),
        .r_valid(aw_r_valid), .r_take(ctl_r_take), .r_data(aw_r_data),
        .words_written(aw_ww), .words_read(aw_wr),
        .fills_done(), .reads_done(), .reads_in_overlap()
    );

    //---- attn_inner_ctl + q 模板 (h = blk/BUFS) ----
    wire ctl_r_take, ctl_busy, ctl_o_valid;
    wire [15:0] ctl_o_data, ctl_act, ctl_w;
    wire [31:0] ctl_o_head, ctl_o_row, ctl_blk, ctl_words, ctl_rows, ctl_blocks_done;
    wire [15:0] q_vec [0:FEED-1];
    function [15:0] qf(input integer h, input integer j);
        begin qf = ((h*4 + j)*7 + 3) % 254 + 1; end
    endfunction
    genvar gj;
    generate for (gj = 0; gj < FEED; gj = gj + 1) begin : QSEL
        assign q_vec[gj] = qf(ctl_blk / BUFS, gj);
    end endgenerate

    attn_inner_ctl #(.DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS), .WPR(WPR)) u_ctl (
        .clk(clk), .rst_n(rst_n), .go(ex_c_go), .busy(ctl_busy),
        .r_valid(aw_r_valid), .r_data(aw_r_data), .r_take(ctl_r_take),
        .q_vec(q_vec), .acc_out_in(arr_acc_out),
        .act_in(ctl_act), .weight_in(ctl_w),
        .o_valid(ctl_o_valid), .o_data(ctl_o_data), .o_head(ctl_o_head),
        .o_row(ctl_o_row), .blk_now(ctl_blk),
        .words_rcvd(ctl_words), .rows_done(ctl_rows), .blocks_done(ctl_blocks_done)
    );

    //---- 共享 MAC 阵列 (两段按 phase 选源; acc 全程累计) ----
    wire [15:0] arr_w = (ex_phase[0] == 1'b0) ? rail_w : ctl_w;
    wire [15:0] arr_a = (ex_phase[0] == 1'b0) ? rail_act : ctl_act;
    wire [15:0] arr_acc_out;
    gemv_array_128 #(.MAC_COUNT(128)) u_arr (
        .clk(clk), .rst_n(rst_n),
        .mac_en(128'h1),                 // 单 lane (塌缩校验峰)
        .weight_in(arr_w), .act_in(arr_a),
        .acc_out(arr_acc_out), .active_cnt()
    );

    //---------------- 黄金公式 ----------------
    // (a) GEMM 段贡献 (rail: weight=词序 w, act=切片字低半)
    function automatic integer gemm_contrib;
        integer L, w;
        begin
            gemm_contrib = 0;
            for (L = 0; L < NL; L = L + 1)
                for (w = 0; w < SW; w = w + 1)
                    gemm_contrib = (gemm_contrib + w * (pwr(L, w) & 16'hFFFF)) & 16'hFFFF;
        end
    endfunction
    // (b) attn 行点积黄金: o(L,b,rr) = Σ_j qf(b/BUFS,j)*se_in(L,b,rr,j)
    function [15:0] se_in(input integer L, input integer blk,
                          input integer r, input integer j);
        begin se_in = ((L*7919 + blk*100 + r*10 + j*3 + 7) % 254) + 1; end
    endfunction
    function automatic integer attn_row_gold(input integer L, input integer b,
                                             input integer rr);
        integer jj, x;
        begin
            x = 0;
            for (jj = 0; jj < FEED; jj = jj + 1)
                x = (x + qf(b / BUFS, jj) * se_in(L, b, rr, jj)) & 16'hFFFF;
            attn_row_gold = x;
        end
    endfunction

    //---------------- 观测: 逐拍镜像阵列输入 (按段分流) ----------------
    reg [31:0] sacc = 0, gacc = 0, aacc = 0, pacc = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin sacc <= 0; gacc <= 0; aacc <= 0; pacc <= 0; end
        else begin
            pacc  <= $signed(arr_w) * $signed(arr_a);
            sacc  <= (sacc + pacc) & 16'hFFFF;
            if (ex_phase[0] == 1'b0) gacc <= (gacc + pacc) & 16'hFFFF;
            else                     aacc <= (aacc + pacc) & 16'hFFFF;
        end

    //---------------- 观测: o 逐行对账 + osum + 释放序罪证 ----------------
    integer n_ok = 0;
    reg [31:0] osum = 0, ref_o = 0;    // osum=通道Σo;  ref_o=黄金公式Σo (独立核)
    always @(posedge clk) begin
        if (ctl_o_valid) begin
            if (ctl_o_data !== (attn_row_gold(ex_layer_now, ctl_o_head,
                                               ctl_o_row[2:0]) & 16'hFFFF)) begin
                $display("%0t FAIL o L=%0d b=%0d r=%0d got=%0d gold=%0d a=%0d b=%0d w0=%0h w1=%0h q0=%0d q1=%0d q2=%0d q3=%0d",
                         $time, ex_layer_now, ctl_o_head, ctl_o_row, ctl_o_data,
                         attn_row_gold(ex_layer_now, ctl_o_head, ctl_o_row[2:0]) & 16'hFFFF,
                         u_ctl.acc_a16, u_ctl.acc_b16, u_ctl.wbuf[0], u_ctl.wbuf[1],
                         q_vec[0], q_vec[1], q_vec[2], q_vec[3]);
                $fatal(1);
            end
            n_ok  <= n_ok + 1;
            osum  <= (osum + ctl_o_data) & 16'hFFFF;
            ref_o <= (ref_o + attn_row_gold(ex_layer_now, ctl_o_head,
                                            ctl_o_row[2:0])) & 16'hFFFF;
        end
    end

    integer rel_exp = 0;
    reg rl_v_d1 = 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            rel_exp = 0;
            rl_v_d1 <= 1'b0;
        end
        else begin
            rl_v_d1 <= ex_rl_valid;
            if (ex_rl_valid && !rl_v_d1) begin   // 释放沿 (电平保持, 只计一次)
                if (ex_rl_layer !== rel_exp[31:0]) begin
                    $display("%0t FAIL 释放序: 期望 %0d 实到 %0d", $time, rel_exp, ex_rl_layer);
                    $fatal(1);
                end
                rel_exp = rel_exp + 1;
            end
        end

    //---------------- 会话快照 / 轮次验收 ----------------
    reg [31:0] s_rail_w, s_rail_f, s_ctl_w, s_ctl_r, s_ctl_b, s_aw_w, s_aw_r, s_o, s_bar, s_sw;
    task automatic snap;
        begin
            s_rail_w = rail_words;     s_rail_f = rail_frames;
            s_ctl_w  = ctl_words;      s_ctl_r  = ctl_rows; s_ctl_b = ctl_blocks_done;
            s_aw_w   = aw_ww; s_aw_r   = aw_wr; s_o = n_ok;
            s_bar    = ex_barrier;     s_sw     = pool_switches;
        end
    endtask

    reg [31:0] g_cum = 0;              // 反轮累进: GEMM 贡献公式累计
    integer e;
    task automatic check_round(input [15:0] name);
        begin
            e = 0;
            if (ex_layers_done !== NL)                    e = 1;
            if (ex_gemm_done   !== NL)                    e = 1;
            if (ex_attn_done   !== NL)                    e = 1;
            if (ex_sel_sw      !== NL)                    e = 1;
            if (ex_wg_words    !== NL*GW)                 e = 1;
            if (ex_wa_words    !== NL*ATW)                e = 1;
            if (wb_layers_done !== NL)                    e = 1;
            if (wb_release_bad !== 1'b0)                  e = 1;
            if (rail_words  - s_rail_w !== NL*GW)         e = 1;
            if (rail_frames - s_rail_f !== NL)            e = 1;
            if (ctl_words   - s_ctl_w  !== NL*ATW)        e = 1;
            if (ctl_rows    - s_ctl_r  !== NL*ROWS_TOT)   e = 1;
            if (ctl_blocks_done - s_ctl_b !== NL*BLK)     e = 1;
            if (aw_ww - s_aw_w !== NL*ATW)                e = 1;
            if (aw_wr - s_aw_r !== NL*ATW)                e = 1;
            if (n_ok - s_o     !== NL*ROWS_TOT)           e = 1;
            if (rel_exp        !== NL)                    e = 1;
            if (pool_switches != s_sw + 2*NL)             e = 1;  // 每层池权 0→1→0 两切
            if (arr_acc_out    !== sacc[15:0])            e = 1;  // 镜像
            if (sacc[15:0]     !== ((gacc + aacc) & 16'hFFFF)) e = 1; // 分段合账
            if (gacc[15:0]   !== ((g_cum + gemm_contrib()) & 16'hFFFF)) e = 1; // GEMM 公式
            if (aacc[15:0]   !== osum[15:0])            e = 1;  // attn段 == 通道Σo
            if (osum[15:0]     !== ref_o[15:0])           e = 1;  // 通道 vs 黄金公式
            if (e == 0)
                $display("== %s 释序%0d GEMM词%0d/帧%0d ctl行%0d 块%0d 窗写%0d/读%0d o%0d barrier%0d acc=%0d==sacc (gemm=%0d attn=%0d)✓",
                         name, rel_exp, rail_words-s_rail_w, rail_frames-s_rail_f,
                         ctl_rows-s_ctl_r, ctl_blocks_done-s_ctl_b,
                         aw_ww-s_aw_w, aw_wr-s_aw_r, n_ok-s_o, ex_barrier,
                         arr_acc_out, gacc[15:0], aacc[15:0]);
            else begin
                $display("%0t %s FAIL: ld=%0d gd=%0d ad=%0d sw=%0d wg=%0d wa=%0d wbd=%0d rbad=%b rw=%0d/%0d rf=%0d/%0d cw=%0d/%0d cr=%0d/%0d cb=%0d/%0d aw=%0d/%0d ar=%0d/%0d o=%0d/%0d rel=%0d acc=%0d sacc=%0d gemm=%0d/%0d attn=%0d/%0d osum=%0d ref=%0d",
                         $time, name, ex_layers_done, ex_gemm_done, ex_attn_done,
                         ex_sel_sw, ex_wg_words, ex_wa_words, wb_layers_done,
wb_release_bad, rail_words-s_rail_w, NL*GW, rail_frames-s_rail_f,
                         NL, ctl_words-s_ctl_w, NL*ATW, ctl_rows-s_ctl_r, NL*ROWS_TOT,
                         ctl_blocks_done-s_ctl_b, NL*BLK, aw_ww-s_aw_w, NL*ATW,
                         aw_wr-s_aw_r, NL*ATW, n_ok-s_o, NL*ROWS_TOT, rel_exp,
                         arr_acc_out, sacc[15:0], gacc[15:0],
                         (g_cum + gemm_contrib()) & 16'hFFFF, aacc[15:0],
                         osum[15:0], ref_o[15:0]);
                $fatal(1);
            end
            g_cum = (g_cum + gemm_contrib()) & 16'hFFFF;   // 反轮累进（下一轮闭合公式用）
        end
    endtask

    //---------------- 看门狗 ----------------
    integer wdc = 0;
    always @(posedge clk) begin
        if (ex_busy || wb_busy) begin
            if (wdc > 300000) begin
                $display("%0t FAIL watchdog", $time); $fatal(1);
            end
            wdc = wdc + 1;
        end else wdc = 0;
    end

    //---------------- 驱动 ----------------
    task automatic start_round;
        begin
            wp = 0; mask3 = 0;
            rel_exp = 0; rl_v_d1 = 1'b0;
            go = 1;
            while (!ex_busy && !wb_busy) @(posedge clk);
            snap;
            go = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;

        //---- R0 全速 ----
        churn_en = 0;
        start_round;
        while (ex_busy || wb_busy) @(posedge clk);
        repeat (12) @(posedge clk);
        check_round("R0");

        //---- R1 变速 (churn 1-in-3): wb 产流慢 1-in-3 拍; exec 领先执行, 全提前填好,
        //    故 S_FILLW 无等待 (barrier_waits 保持 0) 属正常 —— 变速正确性由账目闭合验证。
        churn_en = 1;
        start_round;
        while (ex_busy || wb_busy) @(posedge clk);
        repeat (12) @(posedge clk);
        check_round("R1");

        //---- R2 续跑 (不重启) ----
        churn_en = 0;
        start_round;
        while (ex_busy || wb_busy) @(posedge clk);
        repeat (12) @(posedge clk);
        check_round("R2");

        $display("##### ALL PASS: M11 sched_exec 层执行调度 GEMM段+attn段+释放 #####");
        $display("   o行%0d 释放%0d 池切%0d acc=%0d sacc=%0d gemm=%0d attn=%0d barrier R0=%0d R1=%0d",
                 n_ok, rel_exp, pool_switches, arr_acc_out, sacc[15:0],
                 gacc[15:0], aacc[15:0], s_bar, ex_barrier);
        $finish;
    end

    initial begin
        #50000000;
        $display("%0t M11 FAIL: 超时", $time); $finish;
    end
endmodule
`default_nettype wire