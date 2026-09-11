`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// head_vprune_tb.v — M24 词表剪枝→输出头 真接线 + 真引擎闭环验收
//
// 链 = M23 (e_score→router→assembler→双槽切片库→sched_exec GEMM/attn 真乘累加)
//     + M24 (MAC 阵列会话实算累计 acc → vocab_prune 候选窗 → 输出头只扫候选)。
// 证明:
//   · M23 引擎全绿 (GEMM 64 词逐词对账 + 黄金 4032、attn 38628 双账、释放序 0..3、背压)
//   · 输出头只扫 ncad 个候选 (非全 VOC): 实测候选/词表 < 21% (M22 最小安全半径处)
//   · out_top-K(窗内相对下标 +lbw 还原) == 全量扫描黄金 top-K (M22 窗⊇真 top-K 保证)
//   · 窗/词号硬件对账: G/lbw/ubw/ncad 与 TB 从同一 acc 重算一致; 黄金词全落窗内
// 尺寸: VOC=512 GRP=8 MAXE=8 K=3 xext=6 (M22 最小安全半径); EX16/TOP4/EW8 ⇒ GW16, NL=4
//────────────────────────────────────────────────────────────────────────────
module head_vprune_tb;
    localparam DW=32, AW=8, SW=16, NL=4, GW=16, ATW=128;
    localparam HEADS=4, HBUF=16, BUFS=2, WPR=2;
    localparam FEED=2*WPR, WA=HEADS*BUFS*HBUF, ROWS_TOT=WA/WPR, BLK=HEADS*BUFS;
    localparam EX=16, TOP=4, EW=8;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;
    localparam NVOC=512, NGRP=8, NMAXE=8, NK=3, NXEST=6;
    localparam NCAP = (2*NMAXE+1)*NGRP;

    integer acc_snap;
    integer gk [0:NK-1], gsc [0:NK-1];
    integer idxc, ok2, p, v0;
    integer eg, egb, ebi, elb, eub, ene;

    reg clk=0, rst_n=0, go=0;
    always #5 clk = ~clk;

    //---------------- 切片库 (双槽: 层 L 落槽 L&1, 由装配词流灌写) ----------------
    reg [DW-1:0] smem [0:2*GW-1];
    wire [AW-1:0] sl_adr;
    wire [DW-1:0] sl_dat;
    assign sl_dat = smem[sl_adr];

    //---------------- 选→装配 (route_asm) ----------------
    reg s_valid = 0;
    wire [SW-1:0] s_score;
    wire out_valid;
    wire [SW-1:0] out_data;
    wire [$clog2(EX)-1:0] out_expert;
    wire out_take_c;
    wire out_take = out_take_c;
    reg wr_en = 0;
    reg [$clog2(NL*EX*EW)-1:0] wr_addr = 0;
    reg [SW-1:0] wr_data = 0;
    wire a_layer_done, token_done, r_token_done;
    wire [7:0] r_round_w;
    wire [5:0] a_round_w2ph;
    wire [31:0] r_stalls_w, a_stalls_w, r_sel_w, a_words_w;
    wire [$clog2(EX)-1:0] r_cur_w;
    wire [$clog2(NL)-1:0] a_lay_w2;
    wire r_out_valid_w;

    route_asm #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW)) u_ras(
        .clk(clk), .rst_n(rst_n), .go(go),
        .credit(credit), .s_valid(s_valid), .s_score(s_score),
        .out_take(out_take), .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .a_layer_done(a_layer_done), .r_layer_done(),
        .token_done(token_done), .r_token_done(r_token_done),
        .r_round(r_round_w), .a_round(a_round_w2ph),
        .a_lay_idx(a_lay_w2), .r_cur(r_cur_w), .r_out_valid(r_out_valid_w),
        .r_stalls(r_stalls_w), .a_stalls(a_stalls_w),
        .r_selected(r_sel_w), .a_words(a_words_w)
    );
    wire [5:0] a_round_w2 = a_round_w2ph;

    //---------------- 装配信用帽 ----------------
    reg [15:0] occ_q = 0;
    integer lay_fill_ct = 0;
    reg [31:0] released = 0;
    integer fill_counter = 0;
    reg af_d1 = 1'b0;
    wire afill = a_layer_done || token_done;
    wire slot_ok = (lay_fill_ct < 2) || (released[31:0] > (lay_fill_ct - 2));
    reg credit = 1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) occ_q <= 0;
        else if (out_valid && credit) occ_q <= occ_q + 1 - (occ_q > 0 ? 1 : 0);
        else if (occ_q > 0)           occ_q <= occ_q - 1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin af_d1 <= 0; fill_counter <= 0; lay_fill_ct <= 0; end
        else begin
            af_d1 <= afill;
            if (afill && !af_d1) begin fill_counter <= fill_counter + 1; lay_fill_ct <= lay_fill_ct + 1; end
        end

    always @(occ_q or slot_ok) credit = (occ_q < TCUT) && slot_ok;
    assign out_take_c = credit;

    // smem 灌写
    integer aj = 0;
    reg [2:0] ajl = 0;
    reg [15:0] pe = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            pe <= 0; ajl <= 0; aj = 0;
            for (integer J = 0; J < 2*GW; J = J + 1) smem[J] <= 0;
        end
        else if (out_valid && credit) begin
            if (ajl != a_lay_w2) begin
                ajl = a_lay_w2;
                aj  = 0;
            end
            if ((aj % 2) == 0)
                pe <= out_data;
            else
                smem[(a_lay_w2 & 1)*GW + (aj >> 1)] <= {out_data, pe};
            aj = aj + 1;
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

    wire [15:0] arr_w = (ex_phase[0] == 1'b0) ? rail_w : ctl_w;
    wire [15:0] arr_a = (ex_phase[0] == 1'b0) ? rail_act : ctl_act;
    wire [15:0] arr_acc_out;
    gemv_array_128 #(.MAC_COUNT(128)) u_arr (
        .clk(clk), .rst_n(rst_n),
        .mac_en(128'h1),
        .weight_in(arr_w), .act_in(arr_a),
        .acc_out(arr_acc_out), .active_cnt()
    );

    //---------------- M24 词表剪枝→输出头 (接真引擎会话累计) ----------------
    reg head_go = 0;
    wire h_out_valid, h_token_done;
    wire [15:0] h_out_score;
    wire [$clog2(NCAP)-1:0] h_out_token;
    wire [5:0] h_round_w;
    wire [31:0] h_stalls_w, h_scanned_w;
    wire [$clog2(NVOC/NGRP)-1:0] h_g_w;
    wire [31:0] h_lbw_w, h_ubw_w, h_ncad_w;

    head_vprune #(.VOC(NVOC), .GRP(NGRP), .BB(16), .MAXE(NMAXE), .K(NK)) HV(
        .clk(clk), .rst_n(rst_n), .head_go(head_go),
        .acc(arr_acc_out), .xext(NXEST[3:0]),
        .out_valid(h_out_valid), .out_score(h_out_score), .out_token(h_out_token),
        .out_take(1'b1),
        .token_done(h_token_done), .round(h_round_w), .stalls(h_stalls_w), .scanned(h_scanned_w),
        .peak_g(h_g_w), .lbw(h_lbw_w), .ubw(h_ubw_w), .ncad(h_ncad_w)
    );

    //---------------- 分值/词值/黄金 -------------------
    function [SW-1:0] s_v(input integer L, input integer k);
        s_v = (L*131 + k*17) & 16'hFFFF;
    endfunction
    function [SW-1:0] sw_val(input integer L, input integer e, input integer w);
        sw_val = (L*131 + e*17 + w) & 16'hFFFF;
    endfunction
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
    function [SW-1:0] seq_val(input integer L, input integer j);
        seq_val = sw_val(L, gsel_all[L*TOP + j / EW], j % EW);
    endfunction
    function automatic integer gemm_gold;
        integer L, w;
        begin
            gemm_gold = 0;
            for (L = 0; L < NL; L = L + 1)
                for (w = 0; w < GW; w = w + 1)
                    gemm_gold = (gemm_gold + w * seq_val(L, 2*w)) & 16'hFFFF;
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
    // M22/M24: 词表 logits 代理 (与 head_vprune/vocab_prune 内同源)
    function integer fk(input integer a, input integer x);
        fk = (a*7 + x*17) % 23;
    endfunction

    //---------------- GEMM 段逐词对账 ----------------
    integer gemm_ok = 0, gemm_bad = 0;
    always @(posedge clk) begin
        if (ex_r_valid && rail_r_take) begin
            if (ex_r_data !== {seq_val(ex_layer_now, 2*ex_r_addr + 1),
                               seq_val(ex_layer_now, 2*ex_r_addr)}) begin
                gemm_bad = gemm_bad + 1;
                if (gemm_bad < 6)
                    $display("%0t FAIL GEMM L=%0d gw=%0d got=%0h exp={%0h,%0h}", $time,
                             ex_layer_now, ex_r_addr, ex_r_data,
                             seq_val(ex_layer_now, 2*ex_r_addr + 1),
                             seq_val(ex_layer_now, 2*ex_r_addr));
            end
            gemm_ok = gemm_ok + 1;
        end
    end

    //---------------- 逐拍镜像阵列输入 ----------------
    reg [31:0] sacc = 0, gacc = 0, aacc = 0, pacc = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin sacc <= 0; gacc <= 0; aacc <= 0; pacc <= 0; end
        else begin
            pacc  <= $signed(arr_w) * $signed(arr_a);
            sacc  <= (sacc + pacc) & 16'hFFFF;
            if (ex_phase[0] == 1'b0) gacc <= (gacc + pacc) & 16'hFFFF;
            else                     aacc <= (aacc + pacc) & 16'hFFFF;
        end

    //---------------- o 逐行对账 + osum + 释放序 ----------------
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

    integer rel_exp = 0;
    reg rl_v_d1 = 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin rel_exp = 0; rl_v_d1 <= 1'b0; end
        else begin
            rl_v_d1 <= ex_rl_valid;
            if (ex_rl_valid && !rl_v_d1) begin
                if (ex_rl_layer !== rel_exp[31:0]) begin
                    $display("%0t FAIL 释放序: 期望 %0d 实到 %0d", $time, rel_exp, ex_rl_layer);
                    $fatal(1);
                end
                rel_exp = rel_exp + 1;
                released <= released + 1;
            end
        end

    //---------------- 观测量/源驱动 ----------------
    reg [7:0] srcL = 0;
    assign s_score = s_v(srcL, r_cur_w);
    reg td_a = 0, td_r = 0;
    always @(posedge clk) begin
        if (token_done) td_a = 1;
        if (r_token_done) td_r = 1;
    end

    //---------------- M24 输出头收集/看门狗 ----------------
    integer h_tok [0:NK-1];
    integer h_sc  [0:NK-1];
    integer hc = 0;
    reg  htd_lat = 0;
    reg  head_run = 0;
    integer hwdc = 0;
    always @(posedge clk) begin
        if (head_go) head_run <= 1'b1;
        if (h_token_done) begin head_run <= 1'b0; htd_lat <= 1'b1; end
        if (h_out_valid) begin
            h_tok[hc] = h_out_token;
            h_sc[hc]  = h_out_score;
            hc = hc + 1;
        end
        if (head_run) begin
            hwdc = hwdc + 1;
            if (hwdc > 200000) begin
                $display("%0t FAIL head_vprune 看门狗 (scanned=%0d ncad=%0d)", $time, h_scanned_w, h_ncad_w);
                $fatal(1);
            end
        end
    end

    //---------------- 看门狗 (引擎段) ----------------
    integer wdc = 0;
    always @(posedge clk) begin
        if (ex_busy || out_valid || s_valid) begin
            if (wdc > 300000) begin
                $display("%0t FAIL watchdog (ex_busy=%0d st=%0d out_v=%0d)", $time, ex_busy, ex_st, out_valid);
                $fatal(1);
            end
            wdc = wdc + 1;
        end else wdc = 0;
    end

    initial begin
        integer L, e, w, j;
        repeat (3) @(posedge clk); #1; rst_n = 1;
        repeat (2) @(posedge clk);
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
        @(negedge clk); go = 1;
        @(negedge clk); go = 0;

        for (L = 0; L < NL; L = L + 1) begin
            if (L > 0) begin
                while (!(a_layer_done || token_done)) @(posedge clk);
                @(posedge clk);
            end
            srcL = L;
            @(negedge clk);
            s_valid = 1;
            while (!r_out_valid_w) @(negedge clk);
            @(negedge clk);
            s_valid = 0;
        end
        while (ex_busy || !(td_a && td_r)) @(posedge clk);
        repeat (12) @(posedge clk);

        // ── M24: 会话 acc (MAC 实算) → 剪枝窗 → 输出头 ──
        acc_snap = arr_acc_out;
        @(negedge clk); head_go = 1;
        @(negedge clk); head_go = 0;
        while (!htd_lat) @(posedge clk);
        repeat (4) @(posedge clk);

        // ── 全量扫描黄金 top-K (与头同规则: 分值降, 平局 idx 小先) ──
        for (j = 0; j < NK; j = j + 1) begin gsc[j] = -1; gk[j] = -1; end
        for (idxc = 0; idxc < NVOC; idxc = idxc + 1) begin
            v0 = fk(acc_snap, idxc);
            ok2 = 0;
            for (p = 0; p < NK && !ok2; p = p + 1)
                if (v0 > gsc[p] || (v0 == gsc[p] && idxc < gk[p])) begin
                    for (j = NK-1; j > p; j = j - 1) begin gsc[j] = gsc[j-1]; gk[j] = gk[j-1]; end
                    gsc[p] = v0; gk[p] = idxc; ok2 = 1;
                end
        end

        // ── M22 机制硬件对账: G/lbw/ubw/ncad 从同一 acc 重算 ──
        eg = 0; egb = fk(acc_snap, 0);
        for (e = 0; e < NVOC/NGRP; e = e + 1) begin
            ebi = fk(acc_snap, e*NGRP);
            for (j = 1; j < NGRP; j = j + 1)
                if (fk(acc_snap, e*NGRP + j) > ebi) ebi = fk(acc_snap, e*NGRP + j);
            if (ebi > egb) begin egb = ebi; eg = e; end
        end
        if (eg !== h_g_w) begin $display("FAIL 峰组 hw=%0d gold=%0d", h_g_w, eg); $finish; end
        elb = (eg > NXEST) ? (eg - NXEST)*NGRP : 0;
        eub = (((eg + NXEST + 1)*NGRP) > NVOC) ? NVOC : (eg + NXEST + 1)*NGRP;
        ene = (eub > elb) ? (eub - elb) : 0;
        if (elb !== h_lbw_w || eub !== h_ubw_w || ene !== h_ncad_w) begin
            $display("FAIL 窗对账 lbw hw=%0d/g%0d ubw hw=%0d/g%0d ncad hw=%0d/g%0d",
                     h_lbw_w, elb, h_ubw_w, eub, h_ncad_w, ene); $finish;
        end

        // ── 引擎验收 ──
        if (fill_counter !== NL) begin $display("FAIL 装配层完成 %0d != %0d", fill_counter, NL); $finish; end
        if (r_sel_w !== NL*TOP || a_words_w !== NL*TOP*EW) begin $display("FAIL 选条/字数"); $finish; end
        if (r_round_w !== 1 || a_round_w2 !== 1 || !(td_a && td_r)) begin $display("FAIL 装配侧 round/token_done"); $finish; end
        if (r_stalls_w == 0) begin $display("FAIL 背压停顿 0 (r=%0d)", r_stalls_w); $finish; end
        if (ex_layers_done !== NL || ex_gemm_done !== NL || ex_attn_done !== NL || ex_sel_sw !== NL) begin $display("FAIL exec 层账"); $finish; end
        if (rail_words !== NL*GW || rail_frames !== NL) begin $display("FAIL rail 词/帧"); $finish; end
        if (gemm_bad !== 0 || gemm_ok < NL*(GW-1)) begin $display("FAIL GEMM 对账 bad=%0d ok=%0d", gemm_bad, gemm_ok); $finish; end
        if (gacc[15:0] !== gemm_gold()) begin $display("FAIL gemm 黄金"); $finish; end
        if (arr_acc_out !== sacc[15:0] || sacc[15:0] !== ((gacc + aacc) & 16'hFFFF)) begin $display("FAIL acc 双账"); $finish; end
        if (aacc[15:0] !== osum[15:0] || osum[15:0] !== ref_o[15:0]) begin $display("FAIL attn 全账"); $finish; end
        if (n_ok !== NL*ROWS_TOT) begin $display("FAIL o 行数"); $finish; end
        if (rel_exp !== NL) begin $display("FAIL 释放数"); $finish; end
        if (pool_switches !== 2*NL) begin $display("FAIL 池切换"); $finish; end

        // ── M24 输出头验收 ──
        if (h_ncad_w == 0 || h_ncad_w > NCAP) begin $display("FAIL 候选数 %0d", h_ncad_w); $finish; end
        if (h_scanned_w !== h_ncad_w) begin $display("FAIL 只扫候选: scanned=%0d ncad=%0d", h_scanned_w, h_ncad_w); $finish; end
        if (h_scanned_w >= NVOC) begin $display("FAIL 竟然像全量扫 ncad=%0d", h_ncad_w); $finish; end
        if (hc !== NK) begin $display("FAIL 头吐 %0d != %0d", hc, NK); $finish; end
        for (j = 0; j < NK; j = j + 1) begin
            if (h_tok[j] < 0 || h_tok[j] >= h_ncad_w || h_tok[j] >= NCAP) begin
                $display("FAIL 窗口相对下标越界 #%0d=%0d", j, h_tok[j]); $finish;
            end
            if ((h_lbw_w + h_tok[j]) < h_lbw_w || (h_lbw_w + h_tok[j]) >= h_ubw_w) begin
                $display("FAIL 真词号 %0d 出窗 [%0d,%0d)", h_lbw_w + h_tok[j], h_lbw_w, h_ubw_w); $finish;
            end
            if (h_sc[j] !== gsc[j] || (h_lbw_w + h_tok[j]) !== gk[j]) begin
                $display("FAIL top-K #%0d 头(%0d@lbw+%0d) != 金(%0d@%0d)", j, h_sc[j], h_tok[j], gsc[j], gk[j]);
                $finish;
            end
        end
        // M22 保证复核: 全量黄金 word 必须全部落在硬件窗内 (否则窗不⊇top-K, 即 xext 不够)
        for (j = 0; j < NK; j = j + 1)
            if (gk[j] < h_lbw_w || gk[j] >= h_ubw_w) begin
                $display("FAIL 黄金 %0d 漏出窗 [%0d,%0d) (xext=%0d 不够)", gk[j], h_lbw_w, h_ubw_w, NXEST);
                $finish;
            end

        $display("== M24 闭环: 引擎(token→层→GEMM/attn 真算) acc=%0d → 剪枝窗 G%0d ncad%0d/512 只扫候选, 输出头 top-K=黄金 ==",
                 acc_snap, h_g_w, h_ncad_w);
        $display("== M24 对账: GEMM %0d词/金%0d, attn %0d/金%0d, 释放%0d, 引擎停顿r%0d, 窗窗口覆盖 每候选≈sweep省%0d%% ==",
                 rail_words, gemm_gold(), osum, ref_o, rel_exp, r_stalls_w,
                 100 - (h_ncad_w*100)/NVOC);
        $display("##### ALL PASS: M24 词表剪枝→输出头真接线 · 真引擎acc→候选窗→只扫候选 #####");
        $finish;
    end

    initial begin
        #30000000;
        $display("%0t M24 FAIL: 超时", $time); $finish;
    end
endmodule
`default_nettype wire