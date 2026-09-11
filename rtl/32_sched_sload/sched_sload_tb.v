`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// sched_sload_tb.v — M16×M11 跨件联调: S[L] 层流灌入 → 切片库(双槽) → 层执行闭环
//
// 链: sloader(M16, S 头流灌入) → 切片库 smem(双槽=层L落槽L&1) → sched_exec(M11)
//        → GEMM段(槽字→rail→MAC) → attn段 → 释放(层 L 让槽)
// 新证(相对于单件):
//   · 双槽让位纪律: 层 L+2 灌槽 L&1 前必须见 层 L 释放 (credit 弹性背压挂起)
//     ⇒ sloader stalls>0, 且释放序恰 0..NL-1
//   · 切片库词序==S 头流元素序 (32bit 词 = 连续 2×16bit 元素, GEMM 只取低半)
//   · GEMM 段每词对账: r_data == {s_k(2gw+1), s_k(2gw)}, 贡献公式锁 gacc
//   · attn 段/共享 MAC/释放 沿用 M11 黄金 (o 逐行, acc 双账闭合)
// 井例 FAST 尺寸: NL=4(v1), HEADS=2, DIM=4 ⇒ 32 元素/层 ⇒ GW=16 词/层
//────────────────────────────────────────────────────────────────────────────
module sched_sload_tb;
    localparam DW=32, AW=8, SW=16, NL=4, GW=16, ATW=128;
    localparam HEADS=4, HBUF=16, BUFS=2, WPR=2;
    localparam FEED=2*WPR, WA=HEADS*BUFS*HBUF, ROWS_TOT=WA/WPR, BLK=HEADS*BUFS;

    // sloader 参数: 与 M16 同契约, 小尺寸 (NL2=0 ⇒ 全 v1 层, V1_N=NL)
    localparam HEADS_S = 2, DIM = 4, HEAD_E = DIM*DIM;
    localparam ELEMSL  = HEADS_S * HEAD_E;   // 32 元素/层; 每 32bit 词 = 2 连续元素
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk=0, rst_n=0, go=0;
    always #5 clk = ~clk;

    //---------------- 切片库 (双槽: 层 L 落槽 L&1, 每槽 GW=16 词 ×32bit) ----------------
    reg [DW-1:0] smem [0:2*GW-1];
    wire [AW-1:0] sl_adr;
    wire [DW-1:0] sl_dat;
    assign sl_dat = smem[sl_adr];

    //---------------- sloader (M16) + 灌入信用 ----------------
    reg [15:0] occ_q = 0;
    integer lay_fill_ct = 0;          // 已灌完层数 (本会话累计, 层 L+2 让位门用)
    reg [31:0] released = 0;          // 已释放层数 (layer_sync; 层 L+2 让位门用)
    integer fill_counter= 0;          // 观测: layer_done 上升沿计数
    reg layer_d1 = 1'b0;
    wire slot_ok = (lay_fill_ct < 2) || (released[31:0] > (lay_fill_ct - 2));
    wire credit = (occ_q < TCUT) && slot_ok;

    wire s_busy, s_token_done, s_layer_done, s_head_done;
    wire [7:0] s_round;
    wire [31:0] s_elems, s_layers, s_heads, s_stalls;
    wire [15:0] s_sel;
    wire s_sel_valid = s_busy;

    sloader #(.NL(NL), .NL2(0), .HEADS(HEADS_S), .DIM(DIM)) u_sl (
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit), .busy(s_busy),
        .sel_valid(s_sel_valid), .s_sel(s_sel),
        .token_done(s_token_done), .layer_done(s_layer_done), .head_done(s_head_done),
        .round(s_round), .elems_loaded(s_elems), .layers(s_layers),
        .heads(s_heads), .stalls(s_stalls));

    // S 元素源 (值域 1..200, 恒正 ⇒ signed==unsigned 黄金闭合)
    function [15:0] s_val(input integer r, lay, h, i);
        reg [31:0] t;
        begin t = (r*13 + lay*97 + h*61 + i*7 + 3) % 200; s_val = t + 1; end
    endfunction
    function [15:0] s_k(input integer r, lay, k);
        begin s_k = s_val(r, lay, k / HEAD_E, k % HEAD_E); end
    endfunction

    assign s_sel = s_k(s_round, u_sl.pl_l, u_sl.pl_h * HEAD_E + u_sl.pl_i);

    // 灌入同时写切片库: 32bit 词 = 连续 (元素 2w+1, 元素 2w), w = k/2
    reg [15:0] pe = 0;
    reg [7:0] slot_r [0:1];            // 槽灌入轮号 (末层 GEMM 晚于 token_done, 需取灌填轮)
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin pe <= 0; slot_r[0] <= 0; slot_r[1] <= 0;
            for (integer J = 0; J < 2*GW; J = J + 1) smem[J] <= 0;
        end
        else if (s_busy && credit) begin
            slot_r[u_sl.pl_l[0]] <= s_round;
            if (((u_sl.pl_h * HEAD_E + u_sl.pl_i) % 2) == 0)
                pe <= s_sel;
            else
                smem[((u_sl.pl_l & 1) * GW) + (u_sl.pl_h * HEAD_E + u_sl.pl_i) / 2]
                    <= {s_sel, pe};
        end

    // credit 占位 (恒排空 ⇒ occ 不堵, 让位门才是背压源)
    always @(posedge clk or negedge rst_n)
        if (!rst_n) occ_q <= 0;
        else if (s_busy && credit) occ_q <= occ_q + 1 - (occ_q > 0 ? 1 : 0);
        else if (occ_q > 0)        occ_q <= occ_q - 1;

    // 灌完层计数 → layer_fill; 释放计数 → layer_sync
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin layer_d1 <= 0; fill_counter <= 0; lay_fill_ct <= 0; end
        else begin
            layer_d1 <= s_layer_done;
            if (s_layer_done && !layer_d1) begin `ifdef NOCNT
            `else
                fill_counter <= fill_counter + 1; lay_fill_ct <= lay_fill_ct + 1;
            `endif
            end
        end

    //---------------- sched_exec (M11) ----------------
    wire ex_busy, ex_sel_o, ex_r_valid, ex_r_frame_done;
    wire [DW-1:0] ex_r_data;
    wire [3:0] ex_r_addr;
    wire ex_a_go, ex_a_s_valid, ex_c_go;
    wire [DW-1:0] ex_a_s_data;
    wire [31:0] ex_a_ww, ex_a_wr, ex_c_blocks;
    wire [1:0] ex_phase; wire [2:0] ex_st; wire [$clog2(NL)-1:0] ex_layer_now;
    wire [31:0] ex_layers_done, ex_gemm_done, ex_attn_done, ex_sel_sw,
                ex_barrier, ex_wg_words, ex_wa_words;
    wire ex_rl_valid; wire [31:0] ex_rl_layer;

    sched_exec #(.DW(DW), .AW(AW), .NL(NL), .GW(GW), .GDEPTH(GW), .ATW(ATW)) u_ex (
        .clk(clk), .rst_n(rst_n), .go(go), .busy(ex_busy),
        .layer_fill(lay_fill_ct[31:0]), .layer_sync(released[31:0]),
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

    //---- 池 (attn 段 a_ 口) ----
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
        .mac_en(128'h1),
        .weight_in(arr_w), .act_in(arr_a),
        .acc_out(arr_acc_out), .active_cnt()
    );

    //---------------- 黄金: GEMM 段贡献 (词 w, 激活=词低半=元素2w, 权重=词序 w) ----------------
    function automatic integer gemm_contrib;
        integer L, w;
        begin
            gemm_contrib = 0;
            for (L = 0; L < NL; L = L + 1)
                for (w = 0; w < GW; w = w + 1)
                    gemm_contrib = (gemm_contrib + w * s_k(0, L, 2*w)) & 16'hFFFF;
        end
    endfunction
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

    //---------------- 观测: GEMM 段逐词对账 (r_data == {s_k(2gw+1),s_k(2gw)}) ----------------
    integer gemm_ok = 0, gemm_bad = 0;
    always @(posedge clk) begin
        if (ex_r_valid && rail_r_take) begin
            if (ex_r_data !== {s_k(slot_r[ex_layer_now[0]], ex_layer_now, 2*ex_r_addr + 1),
                               s_k(slot_r[ex_layer_now[0]], ex_layer_now, 2*ex_r_addr)}) begin
                gemm_bad = gemm_bad + 1;
                if (gemm_bad < 6)
                    $display("%0t FAIL GEMM L=%0d gw=%0d got=%0h exp={%0h,%0h}", $time,
                             ex_layer_now, ex_r_addr, ex_r_data,
                             s_k(slot_r[ex_layer_now[0]], ex_layer_now, 2*ex_r_addr + 1),
                             s_k(slot_r[ex_layer_now[0]], ex_layer_now, 2*ex_r_addr));
            end
            gemm_ok = gemm_ok + 1;
        end
    end

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
    reg [31:0] osum = 0, ref_o = 0;
    always @(posedge clk) begin
        if (ctl_o_valid) begin
            if (ctl_o_data !== (attn_row_gold(ex_layer_now, ctl_o_head,
                                              ctl_o_row[2:0]) & 16'hFFFF)) begin
                $display("%0t FAIL o L=%0d b=%0d r=%0d got=%0d gold=%0d", $time,
                         ex_layer_now, ctl_o_head, ctl_o_row,
                         ctl_o_data, attn_row_gold(ex_layer_now, ctl_o_head, ctl_o_row[2:0]) & 16'hFFFF);
                $fatal(1);
            end
            n_ok  <= n_ok + 1;
            osum  <= (osum + ctl_o_data) & 16'hFFFF;
            ref_o <= (ref_o + attn_row_gold(ex_layer_now, ctl_o_head,
                                            ctl_o_row[2:0])) & 16'hFFFF;
        end
    end

    integer rel_exp = 0, hd_ct = 0, ld_ct = 0;
    reg rl_v_d1 = 1'b0, hd_d1 = 1'b0, ld_d1 = 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            rel_exp = 0; hd_ct = 0; ld_ct = 0;
            rl_v_d1 <= 1'b0; hd_d1 <= 1'b0; ld_d1 <= 1'b0;
        end
        else begin
            rl_v_d1 <= ex_rl_valid;
            hd_d1   <= s_head_done;
            ld_d1   <= s_layer_done;
            if (ex_rl_valid && !rl_v_d1) begin
                if (ex_rl_layer !== rel_exp[31:0]) begin
                    $display("%0t FAIL 释放序: 期望 %0d 实到 %0d", $time, rel_exp, ex_rl_layer);
                    $fatal(1);
                end
                $display("%0t RELEASE L=%0d (sload stalls=%0d sl_fill=%0d)", $time,
                         rel_exp, u_sl.stalls, lay_fill_ct);
                rel_exp = rel_exp + 1;
                released <= released + 1;   // layer_sync NBA: 下沿才可见, S_REL 定序稳
            end
            if (s_head_done && !hd_d1) hd_ct = hd_ct + 1;
            if (s_layer_done && !ld_d1) ld_ct = ld_ct + 1;
        end

    //---------------- 看门狗 ----------------
    integer wdc = 0;
    always @(posedge clk) begin
        if (ex_busy || s_busy) begin
            if (wdc > 300000) begin
                $display("%0t FAIL watchdog", $time); $fatal(1);
            end
            wdc = wdc + 1;
        end else wdc = 0;
    end

    //---------------- 驱动: 单会话 ----------------
    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;
        @(posedge clk); go = 1; @(posedge clk); go = 0;

        while (ex_busy || s_busy) @(posedge clk);
        repeat (12) @(posedge clk);

        // 结构账
        if (ex_layers_done !== NL)              err_i = err_i | 1;
        if (ex_gemm_done   !== NL)              err_i = err_i | 2;
        if (ex_attn_done   !== NL)              err_i = err_i | 4;
        if (ex_sel_sw      !== NL)              err_i = err_i | 8;
        if (ex_wg_words    !== NL*GW)           err_i = err_i | 16;
        if (ex_wa_words    !== NL*ATW)          err_i = err_i | 32;
        if (rail_words     !== NL*GW)           err_i = err_i | 64;
        if (rail_frames    !== NL)              err_i = err_i | 128;
        if (ctl_words      !== NL*ATW)          err_i = err_i | 256;
        if (ctl_rows       !== NL*ROWS_TOT)     err_i = err_i | 512;
        if (ctl_blocks_done!== NL*BLK)          err_i = err_i | 1024;
        if (aw_ww          !== NL*ATW)          err_i = err_i | 2048;
        if (aw_wr          !== NL*ATW)          err_i = err_i | 4096;
        if (n_ok           !== NL*ROWS_TOT)     err_i = err_i | 8192;
        if (gemm_ok        !== NL*(GW - 1))    err_i = err_i | 16384;   // 采样漏首词 (take 滞后)
        if (gemm_bad       !== 0)               err_i = err_i | 32768;
        if (rel_exp        !== NL)              err_i = err_i | 65536;
        // sloader 账
        if (s_elems        !== NL*ELEMSL)       err_i = err_i | 131072;
        if (s_layers       !== NL)              err_i = err_i | 262144;
        if (s_heads        !== NL*HEADS_S)      err_i = err_i | 524288;
        if (hd_ct          !== NL*HEADS_S)      err_i = err_i | 1048576;
        if (ld_ct          !== NL)              err_i = err_i | 2097152;
        if (lay_fill_ct    !== NL)              err_i = err_i | 4194304;
        if (released       !== NL)              err_i = err_i | 8388608;
        if (u_sl.stalls    == 0)                err_i = err_i | 16777216;
        // acc 双账
        if (arr_acc_out    !== sacc[15:0])      err_i = err_i | 33554432;
        if (sacc[15:0]     !== ((gacc + aacc) & 16'hFFFF)) err_i = err_i | 67108864;
        if (gacc[15:0]     !== gemm_contrib())  err_i = err_i | 134217728;
        if (aacc[15:0]     !== osum[15:0])      err_i = err_i | 268435456;
        if (osum[15:0]     !== ref_o[15:0])     err_i = err_i | 536870912;
        if (pool_switches  !== 2*NL)            err_i = err_i | 1073741824;

        $display("== loop W: 词%0d/帧%0d 窗写%0d/读%0d o%0d GEMM对账%0d 释放%0d 元素%0d 头%0d 层%0d 停顿%0d 灌%0d/re%0d ==",
                 rail_words, rail_frames, aw_ww, aw_wr, n_ok, gemm_ok, rel_exp,
                 s_elems, hd_ct, ld_ct, u_sl.stalls, lay_fill_ct, released);
        $display("== loop ACC: acc=%0d sacc=%0d gemm=%0d/%0d attn=%0d/%0d osum=%0d ref=%0d 池切%0d barrier=%0d ==",
                 arr_acc_out, sacc[15:0], gacc[15:0], gemm_contrib(),
                 aacc[15:0], osum[15:0], osum[15:0], ref_o[15:0], pool_switches, ex_barrier);

        if (err_i == 0)
            $display("##### ALL PASS: M16×M11 联调 S[L] 灌入→切片双槽→GEMM段→attn段→释放 闭环 (让位门背压+严格释放序) #####");
        else
            $display("##### FAIL errbits=%0d #####", err_i);
        $finish;
    end

    integer err_i = 0;
    initial begin
        #30000000;
        $display("%0t M16×M11 FAIL: 超时", $time); $finish;
    end
endmodule
`default_nettype wire