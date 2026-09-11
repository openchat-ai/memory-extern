`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// decode_auto_tb.v — M25 连续多步解码闭环: 真引擎×TN token 自回归链
//
// 每 token t 一轮完整会话:
//   e_score(依上一发出的 argmax token 反馈成种子 fb[t]) → 选 top-T → 装配吐流 →
//   双槽切片库 → sched_exec GEMM/attn 真乘累加 (MAC 阵列跨会话持续累加) → 阵累计
//   增量 dTotal_t = 本 token 会话实算贡献 → 剪枝窗 (M24) → 输出头只扫候选 → top-K
//   (argmax = 本步发出 token)。逐 token 黄金:
//   · gsel/装配词流由 s_v_t (含 fb 反馈) 重算, GEMM 逐词对账 (monitor 按 tok_now 取金)
//   · 增量对账: dG=阵gacc增量==gemm金_t, dA=阵aacc增量==attn常数, dT==(dG+dA)&0xFFFF
//   · 剪枝窗硬件对账 (G/lbw/ubw/ncad) 与头 top-K==fk(dT) 全量黄金逐 token 一致
//   · 会话账: fill/释放/rail/o/池切全累计, 释放序跨会话严格 0..NL-1 回绕
// 尺寸: TN=12 token; EX16/TOP4/EW8⇒GW16, NL=4; VOC=512 GRP=8 MAXE=8 K=3 xext=6
//────────────────────────────────────────────────────────────────────────────
module decode_auto_tb;
    localparam DW=32, AW=8, SW=16, NL=4, GW=16, ATW=128;
    localparam HEADS=4, HBUF=16, BUFS=2, WPR=2;
    localparam FEED=2*WPR, WA=HEADS*BUFS*HBUF, ROWS_TOT=WA/WPR, BLK=HEADS*BUFS;
    localparam EX=16, TOP=4, EW=8;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;
    localparam NVOC=512, NGRP=8, NMAXE=8, NK=3, NXEST=6;
    localparam NCAP = (2*NMAXE+1)*NGRP;
    localparam TN = 12;
    // M27 随机化压力 profile: 0=基线(原线性LUT+无节流), 1/2/3=随机LUT种子+消费侧节流
    parameter integer PROFILE = 0;
    localparam [15:0] SEEDB = (PROFILE == 1) ? 16'h1234 :
                              (PROFILE == 2) ? 16'h5555 :
                              (PROFILE == 3) ? 16'hCAFE : 16'h0000;
    localparam [1:0]  THRM   = (PROFILE == 1) ? 2'd1 :
                               (PROFILE == 2) ? 2'd2 :
                               (PROFILE == 3) ? 2'd3 : 2'd0;

    reg clk=0, rst_n=0, go=0;
    always #5 clk = ~clk;

    //---------------- 切片库 ----------------
    reg [DW-1:0] smem [0:2*GW-1];
    wire [AW-1:0] sl_adr;
    wire [DW-1:0] sl_dat;
    assign sl_dat = smem[sl_adr];

    //---------------- 选→装配 ----------------
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
    reg start_tok = 0;
    wire afill = a_layer_done || token_done;
    wire slot_ok = (lay_fill_ct < 2) || (released[31:0] > (lay_fill_ct - 2));
    reg credit = 1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) occ_q <= 0;
        else if (out_valid && credit) occ_q <= occ_q + 1 - (occ_q > 0 ? 1 : 0);
        else if (occ_q > 0)           occ_q <= occ_q - 1;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin af_d1 <= 0; fill_counter <= 0; lay_fill_ct <= 0; end
        else if (start_tok) begin af_d1 <= 0; lay_fill_ct <= 0; end
        else begin
            af_d1 <= afill;
            if (afill && !af_d1) begin fill_counter <= fill_counter + 1; lay_fill_ct <= lay_fill_ct + 1; end
        end

    always @(occ_q or slot_ok or th_low) credit = (occ_q < TCUT) && slot_ok && !th_low;
    assign out_take_c = credit;

    // M27 消费侧节流: THRM>0 定期断信 → 强制装配 EMIT-停拍 (a_stalls) / router 停表
    reg [7:0] tc = 0;
    reg th_low = 1'b0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin tc <= 0; th_low <= 0; end
        else begin
            tc <= tc + 1;
            th_low <= (THRM == 2'd1) ? (tc[2:0] == 3'd5)
                    : (THRM == 2'd2) ? ((tc[2:0] >= 3'd2) && (tc[2:0] < 3'd5))
                    : (THRM == 2'd3) ? tc[0]
                    : 1'b0;
        end

    integer aj = 0;
    reg [2:0] ajl = 0;
    reg [15:0] pe = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            pe <= 0; ajl <= 0; aj = 0;
            for (integer J = 0; J < 2*GW; J = J + 1) smem[J] <= 0;
        end
        else if (out_valid && credit) begin
            if (ajl != a_lay_w2) begin ajl = a_lay_w2; aj  = 0; end
            if ((aj % 2) == 0) pe <= out_data;
            else smem[(a_lay_w2 & 1)*GW + (aj >> 1)] <= {out_data, pe};
            aj = aj + 1;
        end

    //---------------- sched_exec ----------------
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

    //---------------- M24 剪枝头 (acc = TB 锁存的每 token 增量) ----------------
    reg head_go = 0;
    reg [15:0] head_acc = 0;
    wire h_out_valid, h_token_done;
    wire [15:0] h_out_score;
    wire [$clog2(NCAP)-1:0] h_out_token;
    wire [5:0] h_round_w;
    wire [31:0] h_stalls_w, h_scanned_w;
    wire [$clog2(NVOC/NGRP)-1:0] h_g_w;
    wire [31:0] h_lbw_w, h_ubw_w, h_ncad_w;

    head_vprune #(.VOC(NVOC), .GRP(NGRP), .BB(16), .MAXE(NMAXE), .K(NK)) HV(
        .clk(clk), .rst_n(rst_n), .head_go(head_go),
        .acc(head_acc), .xext(NXEST[3:0]),
        .out_valid(h_out_valid), .out_score(h_out_score), .out_token(h_out_token),
        .out_take(1'b1),
        .token_done(h_token_done), .round(h_round_w), .stalls(h_stalls_w), .scanned(h_scanned_w),
        .peak_g(h_g_w), .lbw(h_lbw_w), .ubw(h_ubw_w), .ncad(h_ncad_w)
    );

    //---------------- 分值/词值/黄金 (含 token 反馈种子) ----------------
    integer fb [0:TN-1];
    function [SW-1:0] s_v_t(input integer t, input integer L, input integer k);
        s_v_t = (L*131 + ((k*17) ^ (fb[t] & 16'h0FFF))) & 16'hFFFF;
    endfunction
    function [SW-1:0] sw_val(input integer L, input integer e, input integer w);
        if (PROFILE == 0) sw_val = (L*131 + e*17 + w) & 16'hFFFF;
        else sw_val = (SEEDB + L*7919 + e*104729 + w*17) & 16'hFFFF;
    endfunction
    integer gsel_all [0:TN*NL*TOP-1];
    task automatic gold_all_t(input integer t);
        integer L, j, k, bi;
        integer doneg [0:EX-1];
        for (L = 0; L < NL; L = L + 1) begin
            for (k = 0; k < EX; k = k + 1) doneg[k] = 0;
            for (j = 0; j < TOP; j = j + 1) begin
                bi = -1;
                for (k = 0; k < EX; k = k + 1)
                    if (!doneg[k])
                        if (bi < 0 ||
                            (s_v_t(t, L, k) > s_v_t(t, L, bi)) ||
                            (s_v_t(t, L, k) == s_v_t(t, L, bi) && k < bi)) bi = k;
                doneg[bi] = 1;
                gsel_all[t*NL*TOP + L*TOP + j] = bi;
            end
        end
    endtask
    function [SW-1:0] seq_val_t(input integer t, input integer L, input integer j);
        seq_val_t = sw_val(L, gsel_all[t*NL*TOP + L*TOP + j / EW], j % EW);
    endfunction
    integer gemm_gold_arr [0:TN-1];
    function automatic integer gemm_gold(input integer t);
        integer L, w;
        begin
            gemm_gold = 0;
            for (L = 0; L < NL; L = L + 1)
                for (w = 0; w < GW; w = w + 1)
                    gemm_gold = (gemm_gold + w * seq_val_t(t, L, 2*w)) & 16'hFFFF;
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
    integer prevO = 0;
    function integer fk(input integer a, input integer x);
        fk = (a*7 + x*17) % 23;
    endfunction

    //---------------- 当前 token (monitor 用) ----------------
    reg [3:0] tok_now = 0;

    //---------------- GEMM 段逐词对账 (按 tok_now 取金) ----------------
    integer gemm_ok = 0, gemm_bad = 0;
    always @(posedge clk) begin
        if (ex_r_valid && rail_r_take) begin
            if (ex_r_data !== {seq_val_t(tok_now, ex_layer_now, 2*ex_r_addr + 1),
                               seq_val_t(tok_now, ex_layer_now, 2*ex_r_addr)}) begin
                gemm_bad = gemm_bad + 1;
                if (gemm_bad < 6)
                    $display("%0t FAIL GEMM t=%0d L=%0d gw=%0d got=%0h exp={%0h,%0h}", $time,
                             tok_now, ex_layer_now, ex_r_addr, ex_r_data,
                             seq_val_t(tok_now, ex_layer_now, 2*ex_r_addr + 1),
                             seq_val_t(tok_now, ex_layer_now, 2*ex_r_addr));
            end
            gemm_ok = gemm_ok + 1;
        end
    end

    reg [31:0] sacc = 0, gacc = 0, aacc = 0, pacc = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin sacc <= 0; gacc <= 0; aacc <= 0; pacc <= 0; end
        else begin
            pacc  <= $signed(arr_w) * $signed(arr_a);
            sacc  <= (sacc + pacc) & 16'hFFFF;
            if (ex_phase[0] == 1'b0) gacc <= (gacc + pacc) & 16'hFFFF;
            else                     aacc <= (aacc + pacc) & 16'hFFFF;
        end

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
        if (!rst_n) begin rel_exp = 0; rl_v_d1 <= 1'b0; released <= 0; end
        else if (start_tok) begin rl_v_d1 <= 1'b0; released <= 0; end
        else begin
            rl_v_d1 <= ex_rl_valid;
            if (ex_rl_valid && !rl_v_d1) begin
                if (ex_rl_layer !== (rel_exp % NL)) begin
                    $display("%0t FAIL 释放序: 期望 %0d 实到 %0d", $time, rel_exp % NL, ex_rl_layer);
                    $fatal(1);
                end
                rel_exp = rel_exp + 1;
                released <= released + 1;
            end
        end

    reg [7:0] srcL = 0;
    assign s_score = ((srcL*131 + ((r_cur_w*17) ^ (seed_r & 16'h0FFF))) & 16'hFFFF);
    reg td_a = 0, td_r = 0;
    always @(posedge clk) begin
        if (token_done) td_a = 1;
        if (r_token_done) td_r = 1;
    end

    //---------------- 输出头收流 (按 tok_now 存) ----------------
    integer h_buf_tok [0:TN*NK-1];
    integer h_buf_sc  [0:TN*NK-1];
    integer hbufi = 0;
    reg head_run = 0;
    always @(posedge clk) begin
        if (head_go) head_run <= 1'b1;
        if (h_token_done) head_run <= 1'b0;
        if (h_out_valid) begin
            h_buf_tok[hbufi] = h_out_token;
            h_buf_sc[hbufi]  = h_out_score;
            hbufi = hbufi + 1;
        end
    end

    //---------------- 删除期看门狗 ----------------
    integer wdc = 0;
    always @(posedge clk) begin
        if (ex_busy || out_valid || s_valid) begin
            if (wdc > 500000) begin
                $display("%0t FAIL watchdog (ex_busy=%0d st=%0d t=%0d)", $time, ex_busy, ex_st, tok_now);
                $fatal(1);
            end
            wdc = wdc + 1;
        end else wdc = 0;
    end
    integer hwdc = 0;
    always @(posedge clk) begin
        if (head_run) begin
            hwdc = hwdc + 1;
            if (hwdc > 200000) begin
                $display("%0t FAIL head_vprune 看门狗 (scanned=%0d ncad=%0d)", $time, h_scanned_w, h_ncad_w);
                $fatal(1);
            end
        end
    end

    //---------------- 逐 token 黄金/运行变量 ----------------
    integer tokstream [0:TN-1];
    integer prevT = 0, prevG = 0, prevA = 0, hr0, dt, dg, da, dO;
    reg [15:0] seed_r = 0;
    integer eg, egb, ebi, elb, eub, ene, e, j, L, w, p, ok2, v0, idxc, t;
    integer gk [0:NK-1], gsc [0:NK-1];
    integer tc_start = 0, tc_cyc_arr [0:TN-1];
    integer racc = 0;
    integer tok_unique = 0, ntok_unique = 0;

    initial begin
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

        // 反馈链: fb[0]=0; fb[t]=f(上一发出 token)
        fb[0] = 0;
        for (t = 1; t < TN; t = t + 1) fb[t] = 0;   // 初值; 循环内逐 token 更新
        for (t = 0; t < TN; t = t + 1) begin
            gold_all_t(t);
            gemm_gold_arr[t] = gemm_gold(t);
        end

        // 每 token 闭环
        for (t = 0; t < TN; t = t + 1) begin
            if (t > 0)
                fb[t] = (fb[t-1]*1664525 + tokstream[t-1]*7 + 11) & 16'hFFFF;   // LCG 搅拌+上步 token 反馈 (防固定点)
            gold_all_t(t);
            gemm_gold_arr[t] = gemm_gold(t);
            seed_r = fb[t];
            tc_start = $time;

            @(negedge clk); start_tok = 1;
            @(posedge clk);
            @(negedge clk); start_tok = 0; tok_now = t; td_a = 0; td_r = 0;
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
            while (ex_busy) @(posedge clk);
            while (!(td_a && td_r)) @(posedge clk);
            repeat (8) @(posedge clk);

            // ── 本 token 增量 (真 MAC 累计差分) ──
            dt = (arr_acc_out - prevT) & 16'hFFFF;
            dg = (gacc[15:0] - prevG[15:0]) & 16'hFFFF;
            da = (aacc[15:0] - prevA[15:0]) & 16'hFFFF;
            prevT = arr_acc_out; prevG = gacc[15:0]; prevA = aacc[15:0];
            dO = (ref_o[15:0] - prevO) & 16'hFFFF;
            prevO = ref_o[15:0];
            racc = (racc + dt) & 16'hFFFF;
            if (dg !== gemm_gold_arr[t]) begin
                $display("FAIL t=%0d gemm增量 %0d != 金 %0d", t, dg, gemm_gold_arr[t]); $finish;
            end
            if (da !== dO) begin
                $display("FAIL t=%0d attn增量 %0d != 镜像 %0d", t, da, dO); $finish;
            end
            if (dt !== ((dg + da) & 16'hFFFF)) begin
                $display("FAIL t=%0d 总增量 %0d != g%0d+a%0d", t, dt, dg, da); $finish;
            end

            // ── 剪枝头: acc=本 token 增量 ──
            @(negedge clk); head_acc = dt[15:0];
            hr0 = h_round_w;
            @(negedge clk); head_go = 1;
            @(negedge clk); head_go = 0;
            while (h_round_w == hr0) @(posedge clk);
            repeat (4) @(posedge clk);

            // ── 全量黄金 top-K (本 token) + 窗硬件对账 ──
            for (j = 0; j < NK; j = j + 1) begin gsc[j] = -1; gk[j] = -1; end
            for (idxc = 0; idxc < NVOC; idxc = idxc + 1) begin
                v0 = fk(dt, idxc);
                ok2 = 0;
                for (p = 0; p < NK && !ok2; p = p + 1)
                    if (v0 > gsc[p] || (v0 == gsc[p] && idxc < gk[p])) begin
                        for (j = NK-1; j > p; j = j - 1) begin gsc[j] = gsc[j-1]; gk[j] = gk[j-1]; end
                        gsc[p] = v0; gk[p] = idxc; ok2 = 1;
                    end
            end
            if (gk[0] < h_lbw_w || gk[0] >= h_ubw_w) begin
                $display("FAIL t=%0d 黄金 argmax %0d 漏出窗 [%0d,%0d)", t, gk[0], h_lbw_w, h_ubw_w); $finish;
            end
            for (j = 0; j < NK; j = j + 1)
                if (h_buf_sc[t*NK + j] !== gsc[j] || (h_lbw_w + h_buf_tok[t*NK + j]) !== gk[j]) begin
                    $display("FAIL t=%0d top-K#%0d 头(%0d@lbw+%0d) != 金(%0d@%0d)",
                             t, j, h_buf_sc[t*NK + j], h_buf_tok[t*NK + j], gsc[j], gk[j]); $finish;
                end

            // ── 本步发出 token (argmax) → 反馈下步 ──
            tokstream[t] = h_lbw_w + h_buf_tok[t*NK + 0];
            tok_unique = 1;
            for (j = 0; j < t; j = j + 1)
                if (tokstream[j] == tokstream[t]) tok_unique = 0;
            ntok_unique = ntok_unique + tok_unique;
            tc_cyc_arr[t] = $time - tc_start;
            if (tc_cyc_arr[t] >= 30000) begin
                $display("FAIL t=%0d 周期超限 %0d", t, tc_cyc_arr[t]); $finish;
            end
            $display("t%0d: acc增量=%0d 窗G%0d [%0d,%0d) ncad%0d/512 发出token=%0d (top-K分%0d..%0d) 会话%0dcyc",
                      t, dt, h_g_w, h_lbw_w, h_ubw_w, h_ncad_w, tokstream[t],
                      h_buf_sc[t*NK + 0], h_buf_sc[t*NK + NK-1], tc_cyc_arr[t]);
        end

        // ── 会话终账 ──
        if (fill_counter !== NL*TN) begin $display("FAIL 装配层完成 %0d != %0d", fill_counter, NL*TN); $finish; end
        if (r_sel_w !== NL*TOP || a_words_w !== TN*NL*TOP*EW) begin
            $display("FAIL 选条/字数 r=%0d/%0d a=%0d/%0d", r_sel_w, NL*TOP, a_words_w, TN*NL*TOP*EW); $finish;
        end
        if (r_round_w !== TN || a_round_w2 !== TN) begin $display("FAIL round r%0d/a%0d != %0d", r_round_w, a_round_w2, TN); $finish; end
        if (h_round_w !== TN) begin $display("FAIL 头 round %0d != %0d", h_round_w, TN); $finish; end
        if (r_stalls_w == 0) begin $display("FAIL 背压停顿 0 (r=%0d)", r_stalls_w); $finish; end
        if (ex_gemm_done !== NL || ex_attn_done !== NL) begin $display("FAIL exec 层账 %0d/%0d", ex_gemm_done, ex_attn_done); $finish; end
        if (rail_words !== TN*NL*GW || rail_frames !== TN*NL) begin $display("FAIL rail 词/帧"); $finish; end
        if (gemm_bad !== 0 || gemm_ok < TN*NL*(GW-1)) begin $display("FAIL GEMM 对账"); $finish; end
        if (n_ok !== TN*NL*ROWS_TOT) begin $display("FAIL o 行数"); $finish; end
        if (rel_exp !== TN*NL) begin $display("FAIL 释放数 %0d != %0d", rel_exp, TN*NL); $finish; end
        if (pool_switches !== 2*TN*NL) begin $display("FAIL 池切换"); $finish; end
        if (hbufi !== TN*NK) begin $display("FAIL 头吐条数 %0d != %0d", hbufi, TN*NK); $finish; end
        if (racc !== arr_acc_out[15:0]) begin
            $display("FAIL 全账累计 %0d != 阵累积 %0d", racc, arr_acc_out); $finish;
        end
        if (ntok_unique < 5) begin
            $display("FAIL 发出 token 多样性 %0d/12 < 5 (自回归退化为常数序列)", ntok_unique); $finish;
        end
        if (THRM != 2'd0 && a_stalls_w == 0) begin
            $display("FAIL 节流下装配 EMIT-停拍路径未激活 (a_stalls=%0d)", a_stalls_w); $finish;
        end

        $display("== M27 P%0d 长序列解码: %0d token 步进链, 会话周期 %0d..%0d ==",
                 PROFILE, TN, tc_cyc_arr[0], tc_cyc_arr[TN-1]);
        $display("== M27 会话账 P%0d: 装配层%0d 选条%0d 词%0d GEMM%0d词/对账%0d o%0d 释放%0d 池切%0d 停r%0d/a%0d 累计%0d 唯一token%0d ==",
                 PROFILE, fill_counter, r_sel_w, a_words_w, rail_words, gemm_ok, n_ok, rel_exp, pool_switches,
                 r_stalls_w, a_stalls_w, racc, ntok_unique);
        $display("##### ALL PASS: M27 随机化压力 P%0d · 真引擎×%0d 剪枝头×%0d, 随机LUT+消费侧节流 长程全账不漂 #####", PROFILE, TN, TN);
        $finish;
    end

    initial begin
        #50000000;
        $display("%0t M25 FAIL: 超时", $time); $finish;
    end
endmodule
`default_nettype wire