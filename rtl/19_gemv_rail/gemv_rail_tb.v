`timescale 1ns/1ps
//────────────────────────────────────────────────────────────────────────────
// gemv_rail_tb.v — GEMM 段读控整链验收 (M4)
//
// 链: 填充任务 -> atile_pingpong(读轨) -> gemv_rail_ctl -> gemv_array_128
//
// 语义: 一帧 = 64 字 = 128 枚 16bit 激活 (128-MAC 一条向量)。ctl 全速消费
// 读轨, 词序权重 look_w(r_addr)=k, 低半激活广播进阵列。
//
// 黄金: 每帧 alo(k)=(k*3+1)&0xFF, 权重=词序 k ->
//   gold1 = Σ_{k=0..63} k*alo(k) (mod 2^16, 16bit acc 回绕), 两帧后 acc=2*gold1。
// 另置镜像累加器 gold_chk: 与 lane 同沿同递推 (acc += $signed(act)*$signed(weight),
// 逐字节复制 lane 递推式), 校验"喂食--累加"自洽。
//────────────────────────────────────────────────────────────────────────────
module gemv_rail_tb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    //---- atile 读轨 ----
    reg         f_start, f_valid;
    reg  [31:0] f_data;
    wire        f_ready, f_sel, any_free;
    wire        r_take, r_valid, r_frame_done, swap;
    wire [31:0] r_data;
    wire [5:0]  r_addr;

    atile_pingpong #(.DW(32), .TDEPTH(64)) u_at (
        .clk(clk), .rst_n(rst_n),
        .f_start(f_start), .f_valid(f_valid), .f_data(f_data),
        .f_ready(f_ready), .f_sel(f_sel), .any_free(any_free),
        .r_take(r_take), .r_valid(r_valid), .r_data(r_data),
        .r_frame_done(r_frame_done), .swap(swap), .r_addr(r_addr),
        .frames_filled(), .frames_read(), .bubbles());

    //---- 读控 ----
    wire [15:0] act_in, weight_in;
    wire        feed;
    wire [31:0] words_fed, frames_done;

    gemv_rail_ctl #(.DW(32), .TDEPTH(64), .AIDX(6)) u_ctl (
        .clk(clk), .rst_n(rst_n),
        .r_valid(r_valid), .r_take(r_take), .r_data(r_data),
        .r_frame_done(r_frame_done), .r_addr(r_addr),
        .act_in(act_in), .weight_in(weight_in), .feed(feed),
        .words_fed(words_fed), .frames_done(frames_done));

    //---- 128-MAC 阵列 ----
    wire [15:0] acc_out;
    wire [7:0]  active_cnt;

    gemv_array_128 #(.MAC_COUNT(128)) u_arr (
        .clk(clk), .rst_n(rst_n),
        .mac_en(128'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF),
        .weight_in(weight_in), .act_in(act_in),
        .acc_out(acc_out), .active_cnt(active_cnt));

    integer fail = 0, q, k;
    integer alo, gold1, gold2;
    reg [31:0] gold_chk = 0;

    // 镜像累加器: 与 MAC lane 逐沿同递推 (仅观测, 不接入回路)
    always @(posedge clk)
        gold_chk <= (gold_chk + ($signed(act_in) * $signed(weight_in))) & 16'hFFFF;

    function [15:0] w16(input integer v);
        begin w16 = v[15:0]; end
    endfunction

    task fw(input integer w);               // 填一帧一字 (两沿隔)
        begin
            f_valid = 1; f_data = w[31:0];
            @(posedge clk);
            f_valid <= 0;
            @(posedge clk);
        end
    endtask

    initial begin
        f_start = 0; f_valid = 0; f_data = 0;
        #20 rst_n = 1; @(posedge clk); @(posedge clk);

        gold1 = 0; gold2 = 0;
        for (q = 0; q < 64; q = q + 1) begin
            alo = ((q * 3 + 1)) & 16'hFFFF;
            gold1 = (gold1 + ((q * alo) & 16'hFFFF)) & 16'hFFFF;
        end
        gold2 = (gold1 * 2) & 16'hFFFF;

        //---------------- 帧 1 -------------------
        f_start = 1; @(posedge clk); f_start = 0;
        for (k = 0; k < 64; k = k + 1) begin
            fw({w16(k*5+2), w16(k*3+1)});
        end
        k = 0;
        while (!r_frame_done && k < 400) begin @(posedge clk); k = k + 1; end
        if (k >= 400) begin $display("  *** 帧1 frame_done 超时"); fail = 1; end
        @(posedge clk); @(posedge clk);

        //---------------- 帧 2 -------------------
        f_start = 1; @(posedge clk); f_start = 0;
        for (k = 0; k < 64; k = k + 1) begin
            fw({w16(k*5+2), w16(k*3+1)});
        end
        k = 0;
        while (!r_frame_done && k < 400) begin @(posedge clk); k = k + 1; end
        if (k >= 400) begin $display("  *** 帧2 frame_done 超时"); fail = 1; end
        @(posedge clk); @(posedge clk);

        //---------------- 验收 -------------------
        $display("== 终态 ==");
        $display("  words_fed=%0d (期望128) frames_done=%0d (期望2) active_cnt=%0d (期望128)",
                 words_fed, frames_done, active_cnt);
        $display("  acc_out=%0d 黄金2帧=%0d 镜像=%0d (喂食自洽=%0d)",
                 acc_out, gold2, gold_chk, (acc_out === gold_chk));
        if (words_fed  !== 128) begin $display("  *** words_fed=%0d 期望128", words_fed); fail = 1; end
        if (frames_done !== 2)  begin $display("  *** frames_done=%0d 期望2", frames_done); fail = 1; end
        if (active_cnt !== 128) begin $display("  *** active_cnt=%0d 期望128", active_cnt); fail = 1; end
        if (acc_out !== gold2)  begin
            $display("  *** 累加错: acc_out=%0d 期望 %0d", acc_out, gold2);
            fail = 1;
        end
        if (acc_out !== gold_chk) begin
            $display("  *** 喂食不自洽: acc_out=%0d 镜像=%0d", acc_out, gold_chk);
            fail = 1;
        end

        if (fail) $display("##################  FAIL ##################");
        else      $display("##### ALL PASS: GEMM 读轨->128-MAC 整链落地 #####");
        $finish;
    end

    initial begin
        #3000000 $display("[timeout] 仿真超时未结束"); $finish;
    end
endmodule