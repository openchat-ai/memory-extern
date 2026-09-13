`timescale 1ps/1ps
// attn_inner_ctl LOCKSTEP 对账: 产品 (q_vec 数组端口) × SF 镜像 (q_vec_p 打包)
// tb 自由度驱动同源: q_vec 数组寄存器同拍对称, q_vec_p = Σ_{gs} q_vec[gs] 按 16*gs 切片
// (与 attn_inner_ctl_sf 的 assign slice 位序一致)。全输出逐拍比对。
module attn_inner_ctl_lockstep_tb;
    localparam DW = 32, HEADS = 2, HBUF = 8, BUFS = 1, WPR = 2, FEED = 2*WPR;
    reg clk = 0, rst_n = 0, go = 0, r_valid = 0;
    reg [DW-1:0] r_data = 0;
    reg [15:0] q_vec [0:FEED-1];
    wire [32*WPR-1:0] q_vec_p;
    wire [15:0] acc_out_in = 0;
    genvar gs;
    for (gs = 0; gs < FEED; gs = gs + 1)
        assign q_vec_p[16*gs +: 16] = q_vec[gs];

    wire busy_p, busy_s, r_take_p, r_take_s, o_valid_p, o_valid_s;
    wire [31:0] blk_now_p, blk_now_s, o_head_p, o_head_s, o_row_p, o_row_s,
                words_rcvd_p, words_rcvd_s, rows_done_p, rows_done_s, blocks_done_p, blocks_done_s;
    wire [15:0] act_in_p, act_in_s, weight_in_p, weight_in_s, o_data_p, o_data_s;

    attn_inner_ctl #(.DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS), .WPR(WPR)) U_P(
        .clk(clk), .rst_n(rst_n), .go(go), .busy(busy_p),
        .r_valid(r_valid), .r_data(r_data), .r_take(r_take_p), .q_vec(q_vec),
        .acc_out_in(acc_out_in), .blk_now(blk_now_p),
        .act_in(act_in_p), .weight_in(weight_in_p),
        .o_valid(o_valid_p), .o_data(o_data_p), .o_head(o_head_p), .o_row(o_row_p),
        .words_rcvd(words_rcvd_p), .rows_done(rows_done_p), .blocks_done(blocks_done_p));
    attn_inner_ctl_sf #(.DW(DW), .HEADS(HEADS), .HBUF(HBUF), .BUFS(BUFS), .WPR(WPR)) U_S(
        .clk(clk), .rst_n(rst_n), .go(go), .busy(busy_s),
        .r_valid(r_valid), .r_data(r_data), .r_take(r_take_s), .q_vec_p(q_vec_p),
        .acc_out_in(acc_out_in), .blk_now(blk_now_s),
        .act_in(act_in_s), .weight_in(weight_in_s),
        .o_valid(o_valid_s), .o_data(o_data_s), .o_head(o_head_s), .o_row(o_row_s),
        .words_rcvd(words_rcvd_s), .rows_done(rows_done_s), .blocks_done(blocks_done_s));

    always #5 clk = ~clk;
    integer mism = 0, cyc, f, snap = 0, m_busy = 0, m_take = 0, m_valid = 0, m_blk = 0;
    integer m_act = 0, m_wt = 0, m_od = 0, m_oh = 0, m_or = 0, m_wc = 0, m_rd = 0, m_bd = 0;
    reg [31:0] lcg;
    function [31:0] rnd; begin lcg = lcg*1664525 + 1013904223; rnd = lcg; end endfunction

    always @(posedge clk) begin
        if (act_in_p !== act_in_s && snap < 6) begin
            $display("SNAP %0t: actP=%04h actS=%04h qv0=%04h qv1=%04h qv2=%04h qv3=%04h qp=%016h",
                $time, act_in_p, act_in_s, q_vec[0], q_vec[1], q_vec[2], q_vec[3], q_vec_p);
            snap = snap + 1;
        end
        if (busy_p !== busy_s) m_busy = m_busy + 1;
        if (r_take_p !== r_take_s) m_take = m_take + 1;
        if (o_valid_p !== o_valid_s) m_valid = m_valid + 1;
        if (blk_now_p !== blk_now_s) m_blk = m_blk + 1;
        if (act_in_p !== act_in_s) m_act = m_act + 1;
        if (weight_in_p !== weight_in_s) m_wt = m_wt + 1;
        if (o_data_p !== o_data_s) m_od = m_od + 1;
        if (o_head_p !== o_head_s) m_oh = m_oh + 1;
        if (o_row_p !== o_row_s) m_or = m_or + 1;
        if (words_rcvd_p !== words_rcvd_s) m_wc = m_wc + 1;
        if (rows_done_p !== rows_done_s) m_rd = m_rd + 1;
        if (blocks_done_p !== blocks_done_s) m_bd = m_bd + 1;
        if (busy_p !== busy_s || r_take_p !== r_take_s || o_valid_p !== o_valid_s ||
            blk_now_p !== blk_now_s || act_in_p !== act_in_s || weight_in_p !== weight_in_s ||
            o_data_p !== o_data_s || o_head_p !== o_head_s || o_row_p !== o_row_s ||
            words_rcvd_p !== words_rcvd_s || rows_done_p !== rows_done_s ||
            blocks_done_p !== blocks_done_s) mism = mism + 1;
    end

    initial begin
        lcg = 32'hADC0_DE11; cyc = 0;
        repeat (4) @(posedge clk); rst_n = 1;
        repeat (1500) begin
            @(posedge clk);
            go       = (rnd() & 63) == 0;
            r_valid  = (rnd() & 3) != 0;
            r_data   = rnd();
            for (f = 0; f < FEED; f = f + 1)
                q_vec[f] <= rnd();
            cyc = cyc + 1;
        end
        $display("拆分 busy=%0d take=%0d valid=%0d blk=%0d act=%0d wt=%0d o_data=%0d o_head=%0d o_row=%0d wc=%0d rd=%0d bd=%0d", m_busy,m_take,m_valid,m_blk,m_act,m_wt,m_od,m_oh,m_or,m_wc,m_rd,m_bd);
        if (mism == 0) $display("LOCKSTEP attn_inner_ctl PASS (%0d cyc, 全输出逐拍一致)", cyc);
        else begin $display("LOCKSTEP MISMATCH count=%0d", mism); $finish(1); end
        $finish;
    end
endmodule
`default_nettype wire