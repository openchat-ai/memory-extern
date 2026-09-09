`timescale 1ns/1ps
//────────────────────────────────────────────────────────────────────────────
// layer_wb_tb.v — wb_channel 功能/阈值/层序守卫测试 (主从协同: push_wd 遇背压自动排水)
//   A) 名义过账: 多 token 顺巡, 内容+tag+层序逐字比对, 推拉守恒, 池终为空
//   B) 阈值 credit: 1500+1500 字背靠背 -> wr_ready 拉低(stalls>0), 峰值 ≤ THRESH+1
//       (背压把占用钉在阈值边, 绝不写满), 排空后恢复可推, 全部清账
//   C) 坏序正控: 同 token 层 5 后接层 3 -> ord_err 置位
//────────────────────────────────────────────────────────────────────────────
module tb;
    localparam DW = 32, DEPTH = 4096, THRESH = 2048;
    reg  clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         wr_valid, rd_ready;
    reg  [DW-1:0] wr_data;
    reg  [1:0]  wr_tag;
    wire        wr_ready, rd_valid, full;
    wire [DW-1:0] rd_data; wire [1:0] rd_tag; wire [31:0] occ;
    wire        ord_err;

    integer stalls, pushes, pops, peak, fail;
    integer model_i;                       // 已比对游标
    integer mx [0:8191];                   // 期望数据
    reg  [1:0] tx [0:8191];                // 期望 tag
    integer i, k, nA, nB;

    wb_channel #(.DW(DW), .DEPTH(DEPTH), .THRESH(THRESH)) u (
        .clk(clk), .rst_n(rst_n),
        .wr_valid(wr_valid), .wr_data(wr_data), .wr_tag(wr_tag), .wr_ready(wr_ready),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_tag(rd_tag), .rd_ready(rd_ready),
        .full(full), .occupancy(occ), .ord_err(ord_err));

    function [31:0] mk_hdr(input [7:0] layer, input [1:0] typ, input [21:0] lenb);
        mk_hdr = {layer, typ, lenb};
    endfunction

    task pop_ck;
        reg [DW-1:0] gd;
        reg [1:0]    gt;
        begin
            while (!rd_valid) @(posedge clk);
            rd_ready = 1;
            gd = rd_data;                    // 边沿前捕获当前字(再看即下一个)
            gt = rd_tag;
            @(posedge clk); rd_ready = 0;
            if (gt !== tx[pops] || gd !== mx[pops]) begin
                $display("  *** MISMATCH at pop %0d: got tag=%0d data=%h want tag=%0d data=%h",
                         pops, gt, gd, tx[pops], mx[pops]);
                fail = 1;
            end
            pops = pops + 1;
        end
    endtask

    task push_w;                       // 遇背压等候(其间派 host 排水), 统计停滞
        input [DW-1:0] d;
        input [1:0]    t;
        begin
            while (!wr_ready) begin
                stalls = stalls + 1;
                pop_ck;
            end
            wr_valid = 1; wr_data = d; wr_tag = t; @(posedge clk);
            wr_valid = 0; pushes = pushes + 1;
            mx[model_i] = d; tx[model_i] = t; model_i = model_i + 1;
            if (occ > peak) peak = occ;
        end
    endtask

    task idle;
        begin wr_valid = 0; rd_ready = 0; @(posedge clk); end
    endtask

    task drain_all;                      // 排空当前池(pops 追平 pushes)
        begin while (pops < pushes) pop_ck; end
    endtask

    initial begin
        #20 rst_n = 1;
        @(posedge clk);
        fail = 0; stalls = 0; pushes = 0; pops = 0; peak = 0; model_i = 0;

        //──── A) 名义过账: t0(L0,L3) barrier t1(L92) barrier ────
        $display("A) 主从协同过账: t0 L0/L3 + t1 L92 (2181 字)...");
        push_w(mk_hdr( 0, 2'd1, 2048), 2'd1);
        for (i = 0; i < 512; i++)  push_w(i, 2'd0);
        push_w(mk_hdr( 3, 2'd1, 2048), 2'd1);
        for (i = 0; i < 512; i++)  push_w(i + 1000, 2'd0);
        push_w(32'hC0000000, 2'd2);                                 // barrier t0
        push_w(mk_hdr(92, 2'd2, 4608), 2'd1);
        for (i = 0; i < 1152; i++) push_w(i + 2000, 2'd0);
        push_w(32'hC0000001, 2'd2);                                 // barrier t1
        nA = pushes;
        $display("  A 期写入 %0d 字, 停滞 %0d 拍, 峰值占用 %0d", nA, stalls, peak);
        drain_all;
        $display("  A 期结算: pushes=%0d pops=%0d FAIL=%0d", pushes, pops, fail);

        //──── B) 阈值 credit: 1500+1500 背靠背 ────
        stalls = 0;
        $display("B) 阈值: 1500+1500 背靠背, cnt>2048 须背靠 host 排水...");
        push_w(mk_hdr(1, 2'd1, 6000), 2'd1);
        for (i = 0; i < 1500; i++) push_w(i + 9000, 2'd0);
        push_w(mk_hdr(2, 2'd1, 6000), 2'd1);
        for (i = 0; i < 1500; i++) push_w(i + 11000, 2'd0);
        nB = pushes - nA;
        if (stalls == 0) begin
            $display("  *** B 期未触发背压(stalls=0)"); fail = 1;
        end else
            $display("  B 期背压 %0d 拍(PASS), 写入 %0d 字, 峰值占用 %0d ≤ THRESH+1=%0d",
                     stalls, nB, peak, THRESH + 1);
        if (peak > THRESH + 1) begin $display("  *** 峰值越栏"); fail = 1; end
        $display("  排空 700 字验证恢复...");
        for (k = 0; k < 700; k = k + 1) pop_ck;
        $display("  700 字后排空后 wr_ready=%0d", wr_ready);
        if (!wr_ready) begin $display("  *** 排空后未恢复可推"); fail = 1; end
        push_w(mk_hdr(3, 2'd2, 8), 2'd1);                           // 恢复后可推
        push_w(32'hDEADBEEF, 2'd0);
        nB = pushes - nA;
        drain_all;

        //──── C) 坏序正控 ────
        $display("C) 坏序: 同 token 层 5 后接层 3 (无 barrier)...");
        push_w(mk_hdr(5, 2'd1, 4), 2'd1);
        push_w(32'h00000001, 2'd0);
        push_w(mk_hdr(3, 2'd1, 4), 2'd1);                            // 必违约
        push_w(32'h00000002, 2'd0);
        drain_all;
        if (!ord_err) begin $display("  *** ord_err 未置位"); fail = 1; end
        else $display("  C 期 ord_err=1 (PASS)");

        //──── 总结算 ────
        idle;
        if (rd_valid) begin $display("  *** 池未排空, 剩 %0d 字", occ); fail = 1; end
        if (pushes != pops) begin
            $display("  *** 推/拉字数不等: %0d / %0d", pushes, pops); fail = 1;
        end
        $display("  总计: pushes=%0d pops=%0d 峰值=%0d", pushes, pops, peak);
        if (fail) begin
            $display("##################  FAIL ##################");
        end else
            $display("==================  ALL PASS ==================");
        $finish;
    end

endmodule
`default_nettype wire