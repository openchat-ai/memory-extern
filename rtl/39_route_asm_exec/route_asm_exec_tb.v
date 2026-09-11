`timescale 1ps/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// route_asm_exec_tb.v — M23 装配→GEMM 真字流挂接: 选→装配前端直接供引擎段
//
// 链: e_score(credit) → router_sel 顶T → assembler 依选中序抽实体块词流 →
//     以词流写 切片库 (双槽, 32bit 词=连续 2×16bit 装配词, 低半=GEMM激活源)
//     → sched_exec(M11) GEMM段(词序 w 为权重, 低半激活) + attn段 + 释放。
// 新证 (相对 M16×M11: 源从 sloader 换成选→装配前端):
//   · 装配词流按 槽L&1/W 序直灌切片库, exec GEMM 逐词对账 r_data=={seq(2w+1),seq(2w)}
//   · gemm 黄金 = Σ_L Σ_w w*seq(L,2w) (装配实体词序权重, 真 MAC 乘累加)
//   · 双槽让位纪律: 装配灌 L+2(=槽 L&1) 前必见 L 释放 (credit 弹性背压 ⇒ 选侧
//     stall>0, 装配 EMIT 背压被读表门前置吸收故恒 0), 释放序恰 0..NL-1
//   · attn 段黄金沿用 M11 (wordval/se_in 与切片内容解耦, 不受装配源影响)
// 尺寸: EX=16, TOP=4, EW=8 ⇒ 每层装配词 TOP*EW=32 → 打包 GW=TOP*EW/2=16 切片词
//       (对标 M16: GW=16 个 32-bit 词/层); NL=4
//────────────────────────────────────────────────────────────────────────────
module route_asm_exec_tb;
    localparam DW=32, AW=8, SW=16, NL=4, GW=16, ATW=128;
    localparam HEADS=4, HBUF=16, BUFS=2, WPR=2;
    localparam FEED=2*WPR, WA=HEADS*BUFS*HBUF, ROWS_TOT=WA/WPR, BLK=HEADS*BUFS;
    localparam EX=16, TOP=4, EW=8;
    localparam FIFO_CAP = 4096, TCUT = FIFO_CAP/2;

    reg clk=0, rst_n=0, go=0;
    always #5 clk = ~clk;

    //---------------- 切片库 (双槽: 层 L 落槽 L&1, 由装配词流灌写) ----------------
    reg [DW-1:0] smem [0:2*GW-1];
    wire [AW-1:0] sl_adr;
    wire [DW-1:0] sl_dat;
    assign sl_dat = smem[sl_adr];

    //---------------- 选→装配 (route_asm: router_sel + assembler) ----------------
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
    wire [31:0] r_round_w;
    wire [31:0] a_round_w2ph;
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
    wire [31:0] a_round_w2 = a_round_w2ph;

    //---------------- 装配信用帽 (occ 恒排空 ⇒ 让位门才是背压源) ----------------
    reg [15:0] occ_q = 0;
    integer lay_fill_ct = 0;
    reg [31:0] released = 0;
    integer fill_counter = 0;
    reg af_d1 = 1'b0;
    wire afill = a_layer_done || token_done;     // 层装配完 (末层=token_done)
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
            if (afill && !af_d1) begin
                fill_counter <= fill_counter + 1;
                lay_fill_ct   <= lay_fill_ct + 1;
            end
        end

    // credit 组合: (occ<TCUT) && slot_ok —— 灌选/装配吐期同一门 (背压传递到选+装配)
    always @(occ_q or slot_ok) credit = (occ_q < TCUT) && slot_ok;
    assign out_take_c = credit;

    // smem 灌写: 装配词 j (层内 0..TOP*EW-1) → 槽 (L&1)*GW, 32bit=连续2词 (低半在前)
    // 层转槽时: 走 if-else 避免既重置 aj 又拿旧 aj 做奇偶, 否则新层首词会
    // 误用旧 pe 写入 smem[0] (例: 旧 aj=15 奇写 → 新层 word0 被吞).
    integer aj = 0;
    reg [2:0] ajl = 0;
    reg [15:0] pe = 0;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            pe <= 0; ajl <= 0; aj = 0;
            for (integer J = 0; J < 2*GW; J = J + 1) smem[J] <= 0;
        end
        else if (out_valid && credit) begin
            if (ajl != a_lay_w2) begin          // 层转槽: 先把 aj 归 0, 再走统一派发
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
    // 装配词 j (层内 0..TOP*EW-1) 的值: 选序 → 专家ID → 词序号
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

    //---------------- GEMM 段逐词对账 (r_data == {seq(2w+1), seq(2w)}) ----------------
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

    //---------------- 逐拍镜像阵列输入 (按段分流) ----------------
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

    //---------------- 看门狗 ----------------
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
        integer L, e, w;
        repeat (3) @(posedge clk); #1; rst_n = 1;
        repeat (2) @(posedge clk);
        // 预灌装配切片 LUT (每实体块 EW 词)
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

        // 逐层: 灌 e_score → router 吐表 → assembler 拉实体块 → 词流写切片库
        for (L = 0; L < NL; L = L + 1) begin
            if (L > 0) begin
                while (!(a_layer_done || token_done)) @(posedge clk);   // 前层装配完 (barrier)
                @(posedge clk);
            end
            srcL = L;
            @(negedge clk);
            s_valid = 1;
            while (!r_out_valid_w) @(negedge clk);     // router 吐表 → 交给装配
            @(negedge clk);
            s_valid = 0;
        end
        while (ex_busy || !(td_a && td_r)) @(posedge clk);
        repeat (12) @(posedge clk);

        // ── 验收 ──
        if (fill_counter !== NL) begin $display("FAIL 装配层完成 %0d != %0d", fill_counter, NL); $finish; end
        if (r_sel_w !== NL*TOP || a_words_w !== NL*TOP*EW) begin
            $display("FAIL route_asm 选条/字数 r=%0d/%0d a=%0d/%0d", r_sel_w, NL*TOP, a_words_w, NL*TOP*EW); $finish;
        end
        if (r_round_w !== 1 || a_round_w2 !== 1 || !(td_a && td_r)) begin
            $display("FAIL 装配侧 round/token_done"); $finish;
        end
        if (r_stalls_w == 0) begin
            $display("FAIL 背压停顿 0 (r=%0d a=%0d)", r_stalls_w, a_stalls_w); $finish;
        end
        if (ex_layers_done !== NL || ex_gemm_done !== NL || ex_attn_done !== NL || ex_sel_sw !== NL) begin
            $display("FAIL exec 层账"); $finish;
        end
        if (rail_words !== NL*GW || rail_frames !== NL) begin
            $display("FAIL rail 词/帧"); $finish;
        end
        if (gemm_bad !== 0 || gemm_ok < NL*(GW-1)) begin
            $display("FAIL GEMM 对账 bad=%0d ok=%0d", gemm_bad, gemm_ok); $finish;
        end
        if (gacc[15:0] !== gemm_gold()) begin
            $display("FAIL gemm 黄金 gacc=%0d gold=%0d", gacc[15:0], gemm_gold()); $finish;
        end
        if (arr_acc_out !== sacc[15:0] || sacc[15:0] !== ((gacc + aacc) & 16'hFFFF)) begin
            $display("FAIL acc 双账"); $finish;
        end
        if (aacc[15:0] !== osum[15:0] || osum[15:0] !== ref_o[15:0]) begin
            $display("FAIL attn 全账"); $finish;
        end
        if (n_ok !== NL*ROWS_TOT) begin $display("FAIL o 行数"); $finish; end
        if (rel_exp !== NL) begin $display("FAIL 释放数 %0d != %0d", rel_exp, NL); $finish; end
        if (pool_switches !== 2*NL) begin $display("FAIL 池切换"); $finish; end

        $display("== M23 route_asm_exec: 装配 选条%0d 词%0d 停顿 r%0d/a%0d; 引擎 GEMM词%0d/帧%0d o%0d 释放%0d ==",
                 r_sel_w, a_words_w, r_stalls_w, a_stalls_w,
                 rail_words, rail_frames, n_ok, rel_exp);
        $display("== M23 ACC: acc=%0d gemm=%0d/%0d attn=%0d/%0d osum=%0d ref=%0d 池切%0d barrier=%0d ==",
                 arr_acc_out, gacc[15:0], gemm_gold(),
                 aacc[15:0], osum[15:0], osum[15:0], ref_o[15:0], pool_switches, ex_barrier);
        $display("##### ALL PASS: M23 装配→GEMM 真字流 · 选→装配→切片库→引擎段乘累加不丢不序 (slot让位背压+严格释放序) #####");
        $finish;
    end

    initial begin
        #30000000;
        $display("%0t M23 FAIL: 超时", $time); $finish;
    end
endmodule
`default_nettype wire