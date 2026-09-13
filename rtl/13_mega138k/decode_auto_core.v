// decode_auto_core.v — SF7: M25 解码主线核心骨架 (上板主目标)
// 与 rtl/41_decode_auto/decode_auto_tb.v 的 8 模块 DUT 网逐点同构。
// 数据面 (s_v_t/gsw/qf/TB 函数) 外源注入: 板上由 ROM/主机供给 (SF5 契约)。
// 状态机: run→go 单发→wait token_done→done (层/轮节奏由 TB 语义在 PC top 细化)。
// 本文件 = PC 综合/布线的结构输入; 产品模块零改动。可直接 iverilog 编译。
module decode_auto_core #(
    parameter DW = 32, AW = 8, SW = 16, NL = 4, GW = 16, ATW = 128,
    parameter HEADS = 4, HBUF = 16, BUFS = 2, WPR = 2, FEED = 2*WPR,
    parameter EX   = 16, TOP  = 4, EW   = 8,
    parameter NVOC = 1024, NGRP = 16, NMAXE = 14, NXEST = 6,
    parameter NCAP = (2*NMAXE+1)*NGRP, NK = 3,
    SELFDRV = 1   // =1 板上自驱: 内嵌 LFSR 分值源跑真链 (确定性 token, 可两次同seed对账);
                  //   数据面外源 (s_valid/s_score/out_take/credit) 被内部替换, H 侧 acc/xext 仍外源。
) (
    input  wire clk, rst_n, run,
    output reg  busy, done,
    // ---- 外源数据面 (对应 TB 的 s_v_t/gsw/qf) ----
    input  wire credit, s_valid, out_take,
    input  wire [SW-1:0]   s_score,
    input  wire [FEED*16-1:0] q_vec_p,       // attn 查询向量打包 (slice: 16*gs, 同 *_sf)
    input  wire [15:0]     head_acc,
    input  wire [3:0]      xext,
    input  wire wr_en, input  wire [$clog2(NL*EX*EW)-1:0] wr_addr, input  wire [SW-1:0] wr_data,
    // ---- 结果/观测 ----
    output wire out_valid, output wire [SW-1:0] out_data, output wire [$clog2(EX)-1:0] out_expert,
    output wire token_done, output wire r_token_done,
    output wire [$clog2(NCAP)-1:0] out_token, output wire [15:0] out_score, output reg  h_go,
    output wire [31:0] r_round, h_round, r_stalls, a_stalls, a_words
);

    // ---------------- route_asm ----------------
    wire r_out_valid_w;
    wire [31:0] r_round_w, a_round_w2ph, a_stalls_w, r_stalls_w, r_sel_w, a_words_w;
    wire [($clog2(EX)-1):0] r_cur_w; wire [$clog2(NL)-1:0] a_lay_w2;

    // 上板构件一律 *_sf 镜像 (ys0.68 兼容: 参数for界/数组端口; 各镜像 LOCKSTEP 已证)
    // ---- 自驱数据面选择 (SELFDRV=1 时接管 s_stream/credit/out_take) ----
    wire int_drv = SELFDRV && (sm == SM_RUN) && !token_done;
    wire [SW-1:0] s_score_in = int_drv ? slfsr[15:0] : s_score;
    wire          s_valid_in = int_drv ? 1'b1       : s_valid;
    wire          out_take_in = SELFDRV ? credit_r  : out_take;
    wire          credit_in   = SELFDRV ? credit_r  : credit;

    route_asm_sf #(.EX(EX), .TOP(TOP), .EW(EW), .NL(NL), .SW(SW)) u_ras(
        .clk(clk), .rst_n(rst_n), .go(go), .credit(credit_in), .s_valid(s_valid_in), .s_score(s_score_in),
        .out_take(out_take_in), .out_valid(out_valid), .out_data(out_data), .out_expert(out_expert),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .a_layer_done(a_layer_done), .r_layer_done(),
        .token_done(token_done), .r_token_done(r_token_done),
        .r_round(r_round_w), .a_round(a_round_w2ph),
        .a_lay_idx(a_lay_w2), .r_cur(r_cur_w), .r_out_valid(r_out_valid_w),
        .r_stalls(r_stalls_w), .a_stalls(a_stalls_w),
        .r_selected(r_sel_w), .a_words(a_words_w)
    );
    wire [31:0] a_round_w2 = a_round_w2ph;

    // ---------------- sched_exec ----------------
    reg [15:0] occ_q = 0; reg af_d1 = 0; reg start_tok = 0; integer lay_fill_ct = 0;
    reg [31:0] released = 0;
    wire afill = a_layer_done || token_done;
    wire slot_ok = (lay_fill_ct < 2) || (released[31:0] > (lay_fill_ct - 2));
    reg credit_r = 1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) occ_q <= 0;
        else if (out_valid && credit_r) occ_q <= occ_q;          // 同拍吐+收存量不动
        else if (occ_q > 0) occ_q <= occ_q - 1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin af_d1 <= 0; lay_fill_ct <= 0; end
        else begin
            af_d1 <= afill;
            if (afill && !af_d1) lay_fill_ct <= lay_fill_ct + 1;
        end
    always @(*) credit_r = SELFDRV ? 1'b1 : ((occ_q < 4096/2) && slot_ok);

    wire ex_busy, ex_sel_o, ex_r_valid, ex_r_frame_done, ex_rl_valid;
    wire [DW-1:0] ex_r_data; wire [3:0] ex_r_addr; wire [31:0] ex_rl_layer;
    wire ex_a_go, ex_a_s_valid, ex_c_go, aw_busy, aw_s_ready;
    wire [DW-1:0] ex_a_s_data; wire [31:0] ex_c_blocks; wire [1:0] ex_phase;
    wire [2:0] ex_st; wire [$clog2(NL)-1:0] ex_layer_now;
    wire [31:0] ex_layers_done, ex_gemm_done, ex_attn_done, ex_sel_sw, ex_barrier, ex_wg_words, ex_wa_words;

    sched_exec #(.DW(DW), .AW(AW), .NL(NL), .GW(GW), .GDEPTH(GW), .ATW(ATW)) u_ex(
        .clk(clk), .rst_n(rst_n), .go(go), .busy(ex_busy),
        .layer_fill(lay_fill_ct[31:0]), .layer_sync(released[31:0]),
        .rl_valid(ex_rl_valid), .rl_layer(ex_rl_layer), .a_busy(aw_busy),
        .sel_o(ex_sel_o), .slice_addr(), .slice_rdata(),
        .r_valid(ex_r_valid), .r_data(ex_r_data), .r_frame_done(ex_r_frame_done),
        .r_addr(ex_r_addr), .r_take(rail_r_take),
        .a_go(ex_a_go), .a_s_valid(ex_a_s_valid), .a_s_data(ex_a_s_data),
        .a_s_ready(aw_s_ready), .a_ww(), .a_wr(),
        .c_go(ex_c_go), .c_busy(ctl_busy), .c_blocks(ex_c_blocks),
        .phase(ex_phase), .st_o(ex_st), .layer_now(ex_layer_now),
        .layers_done(ex_layers_done), .gemm_done(ex_gemm_done),
        .attn_done(ex_attn_done), .sel_switches(ex_sel_sw),
        .barrier_waits(ex_barrier), .wg_words(ex_wg_words), .wa_words(ex_wa_words)
    );

    // ---------------- gemv_rail_ctl ----------------
    wire rail_r_take; wire [15:0] rail_act, rail_w;
    wire [31:0] rail_words, rail_frames;
    gemv_rail_ctl #(.DW(DW), .TDEPTH(GW), .AIDX(4)) u_rail(
        .clk(clk), .rst_n(rst_n),
        .r_valid(ex_r_valid), .r_take(rail_r_take), .r_data(ex_r_data),
        .r_frame_done(ex_r_frame_done), .r_addr(ex_r_addr),
        .act_in(rail_act), .weight_in(rail_w), .feed(),
        .words_fed(rail_words), .frames_done(rail_frames)
    );

    // ---------------- sram_pool_arb ----------------
    wire a_rdy; wire [DW-1:0] a_rdata;
    wire aw_a_valid, aw_a_we; wire [AW-1:0] aw_a_addr; wire [DW-1:0] aw_a_wdata;
    sram_pool_arb #(.AW(AW), .DW(DW)) u_pool(
        .clk(clk), .rst_n(rst_n), .sel(ex_sel_o),
        .g_valid(1'b0), .g_we(1'b0), .g_addr({AW{1'b0}}), .g_wdata({DW{1'b0}}),
        .g_rdy(), .g_rdata(),
        .a_valid(aw_a_valid), .a_we(aw_a_we), .a_addr(aw_a_addr),
        .a_wdata(aw_a_wdata), .a_rdy(a_rdy), .a_rdata(a_rdata),
        .g_ops(), .a_ops(), .switches()
    );

    // ---------------- attn_window ----------------
    wire aw_r_valid; wire [DW-1:0] aw_r_data;
    attn_window #(.AW(AW), .DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS)) aw(
        .clk(clk), .rst_n(rst_n), .go(ex_a_go), .busy(aw_busy),
        .a_valid(aw_a_valid), .a_we(aw_a_we), .a_addr(aw_a_addr),
        .a_wdata(aw_a_wdata), .a_rdy(a_rdy), .a_rdata(a_rdata),
        .s_valid(ex_a_s_valid), .s_data(ex_a_s_data), .s_ready(aw_s_ready),
        .r_valid(aw_r_valid), .r_take(ctl_r_take), .r_data(aw_r_data),
        .words_written(), .words_read(), .fills_done(), .reads_done(), .reads_in_overlap()
    );

    // ---------------- attn_inner_ctl (SF 打包镜像; ys0.68 不支持数组端口) ----------------
    wire ctl_r_take, ctl_busy, ctl_o_valid; wire [15:0] ctl_o_data, ctl_act, ctl_w;
    wire [31:0] ctl_o_head, ctl_o_row, ctl_blk, ctl_words, ctl_rows, ctl_blocks_done;

    attn_inner_ctl_sf #(.DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS), .WPR(WPR)) u_ctl(
        .clk(clk), .rst_n(rst_n), .go(ex_c_go), .busy(ctl_busy),
        .r_valid(aw_r_valid), .r_data(aw_r_data), .r_take(ctl_r_take),
        .q_vec_p(q_vec_p), .acc_out_in(arr_acc_out),
        .act_in(ctl_act), .weight_in(ctl_w),
        .o_valid(ctl_o_valid), .o_data(ctl_o_data), .o_head(ctl_o_head),
        .o_row(ctl_o_row), .blk_now(ctl_blk),
        .words_rcvd(ctl_words), .rows_done(ctl_rows), .blocks_done(ctl_blocks_done)
    );

    // ---------------- gemv_array_128 (占位核, PC 替换真阵) ----------------
    wire [15:0] arr_w = (ex_phase[0] == 1'b0) ? rail_w  : ctl_w;
    wire [15:0] arr_a = (ex_phase[0] == 1'b0) ? rail_act : ctl_act;
    wire [15:0] arr_acc_out;
    gemv_array_128 #(.MAC_COUNT(128)) u_arr(
        .clk(clk), .rst_n(rst_n), .mac_en(128'h1),
        .weight_in(arr_w), .act_in(arr_a),
        .acc_out(arr_acc_out), .active_cnt()
    );

    // ---------------- head_vprune (SF 镜像: cand 打包, ys0.68 数组端口) ----------------
    wire h_out_valid, h_token_done; wire [15:0] h_out_score;
    wire [$clog2(NCAP)-1:0] h_out_token;
    wire [31:0] h_round_w, h_stalls_w, h_scanned_w;
    wire [$clog2(NVOC/NGRP)-1:0] h_g_w; wire [31:0] h_lbw_w, h_ubw_w, h_ncad_w;
    head_vprune_sf #(.VOC(NVOC), .GRP(NGRP), .BB(16), .MAXE(NMAXE), .K(NK)) HV(
        .clk(clk), .rst_n(rst_n), .head_go(h_go),
        .acc(head_acc), .xext(xext),
        .out_valid(h_out_valid), .out_score(h_out_score), .out_token(h_out_token),
        .out_take(1'b1),
        .token_done(h_token_done), .round(h_round_w), .stalls(h_stalls_w), .scanned(h_scanned_w),
        .peak_g(h_g_w), .lbw(h_lbw_w), .ubw(h_ubw_w), .ncad(h_ncad_w)
    );

    assign out_score  = h_out_score;
    assign out_token  = h_out_token;
    assign r_round    = r_round_w;
    assign h_round    = h_round_w;
    assign r_stalls   = r_stalls_w;
    assign a_stalls   = a_stalls_w;
    assign a_words    = a_words_w;

    // ---------------- 状态机 (run→go→wait→done) + 自驱 LFSR ----------------
    reg go = 0;
    reg [31:0] slfsr = 32'hC0FF_EE13;
    reg [1:0] sm = 0;
    reg h_td_cap = 0;
    localparam SM_IDLE = 2'd0, SM_GO = 2'd1, SM_RUN = 2'd2, SM_DONE = 2'd3;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            sm <= SM_IDLE; go <= 0; busy <= 0; done <= 0; h_go <= 0; start_tok <= 0; slfsr <= 32'hC0FF_EE13; h_td_cap <= 0;
        end else begin
            if (int_drv) slfsr <= {slfsr[30:0], slfsr[31] ^ slfsr[21] ^ slfsr[1] ^ slfsr[0]};
            case (sm)
                SM_IDLE: if (run) begin
                    sm <= SM_GO; go <= 1'b1; h_go <= 1'b1; start_tok <= 1'b1; h_td_cap <= 0;
                end
                SM_GO: begin
                    go <= 1'b0; h_go <= 1'b0; start_tok <= 1'b0;
                    busy <= 1'b1; sm <= SM_RUN;
                end
                SM_RUN: begin
                    if (h_token_done) h_td_cap <= 1'b1;
                    if (token_done && h_td_cap) begin
                        sm <= SM_DONE; busy <= 1'b0; done <= 1'b1;
                    end
                end
                SM_DONE: begin
                    done <= 1'b0;
                    if (!run) sm <= SM_IDLE;
                end
            endcase
        end
endmodule