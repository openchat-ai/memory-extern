`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// relay_fifo_tb.v — DMA 弹性转载 FIFO 验收 (M7)
//
// 三幕 (对应基线语义):
//   P0 单笔结构性: PAYLOAD=128 字整笔灌入, 笔内绝不停 (w_ready 恒高),
//      max_used==128, over_half(256 阈值)未触; 整笔排出对账.
//   P1 credit 闸: B(128)+C(128) 灌至过阈, 途中单笔不停; credit 下新笔暂停
//      等主机排走 1 字后放行, 续推 D; 全排空, 顺序连续性 seq_w==seq_r.
//   P2 转载站慢宿主: 3 整包逐包发, 每 4 拍才吃 1 字, credit 在中途闸新包;
//      全程无丢 (顺序对账), 收支平衡, 末态空.
// 数据模式: pat(k)=(k*131+7)&32'hFFFF_FFFF, 全链按全局序号唯一对账.
//────────────────────────────────────────────────────────────────────────────
`include "relay_fifo.v"

module relay_fifo_tb;
    localparam DW = 32, DEPTH = 512, PAYLOAD = 128;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg            w_valid = 0;
    reg  [DW-1:0]  w_data = 0;
    wire           w_ready;
    wire           r_valid; wire [DW-1:0] r_data;
    reg            r_take = 0;
    wire [31:0]    used; wire full, empty, over_half;
    wire [31:0]    w_ops, r_ops; wire [31:0] max_used;

    relay_fifo #(.DW(DW), .DEPTH(DEPTH)) u (
        .clk(clk), .rst_n(rst_n),
        .w_valid(w_valid), .w_data(w_data), .w_ready(w_ready),
        .r_valid(r_valid), .r_data(r_data), .r_take(r_take),
        .used(used), .full(full), .empty(empty), .over_half(over_half),
        .w_ops(w_ops), .r_ops(r_ops), .max_used(max_used)
    );

    function [DW-1:0] pat(input integer k);
        begin
            pat = (k * 131 + 7) & 32'hFFFFFFFF;
        end
    endfunction

    integer seq_w = 0, seq_r = 0;
    integer stalls = 0;
    integer saw_credit = 0;

    task autopush(input [DW-1:0] d);
        begin
            if (!w_ready) begin
                stalls = stalls + 1;
                while (!w_ready) @(posedge clk);
            end
            #1; w_valid = 1'b1; w_data = d;
            @(posedge clk);            // 接受沿: w_valid&&w_ready 采样均高
            #1; w_valid = 1'b0;
        end
    endtask

    task autopop;
        begin
            while (!r_valid) @(posedge clk);
            #1;
            if (r_data !== pat(seq_r)) begin
                $display("%0t FAIL 出序错误 got=%0d exp=%0d seq=%0d",
                         $time, r_data, pat(seq_r), seq_r);
                $fatal;
            end
            r_take = 1'b1;
            @(posedge clk);
            #1; r_take = 1'b0;
            seq_r = seq_r + 1;
        end
    endtask

    integer k, npp;
    integer ph2_payloads = 3;

    initial begin
        repeat (3) @(posedge clk); #1; rst_n = 1;
        repeat (3) @(posedge clk);
        #1;

        //════════ P0: 单笔结构性 (笔内不停, 整笔对账) ════════
        stalls = 0;
        for (k = 0; k < PAYLOAD; k = k + 1) autopush(pat(seq_w + k));
        seq_w = seq_w + PAYLOAD;
        if (stalls !== 0) begin
            $display("%0t FAIL P0 单笔笔内不该停 (stalls=%0d)", $time, stalls); $fatal;
        end
        if (max_used !== PAYLOAD) begin
            $display("%0t FAIL P0 max_used=%0d (期望 %0d)", $time, max_used, PAYLOAD); $fatal;
        end
        if (over_half !== 0) begin
            $display("%0t FAIL P0 未过阈却 credit", $time); $fatal;
        end
        for (k = 0; k < PAYLOAD; k = k + 1) autopop;
        if (seq_r !== seq_w || !empty) begin
            $display("%0t FAIL P0 收平/空: sr=%0d sw=%0d empty=%b", $time, seq_r, seq_w, empty); $fatal;
        end
        $display("%0t P0 通过: 单笔结构性 128 字整灌整排, 笔内零停", $time);

        //════════ P1: 50% credit 闸 ════════
        stalls = 0;
        for (k = 0; k < PAYLOAD; k = k + 1) autopush(pat(seq_w + k));
        seq_w = seq_w + PAYLOAD;                      // used 128
        if (over_half !== 0) begin
            $display("%0t FAIL P1 B 后不该过阈", $time); $fatal;
        end
        stalls = 0;
        for (k = 0; k < PAYLOAD; k = k + 1) autopush(pat(seq_w + k));
        seq_w = seq_w + PAYLOAD;                      // used 256
        if (stalls !== 0) begin
            $display("%0t FAIL P1 单笔在途中绝不停 (stalls=%0d)", $time, stalls); $fatal;
        end
        if (over_half !== 1) begin
            $display("%0t FAIL P1 已过阈 credit 未置", $time); $fatal;
        end

        // credit 闸: 新笔等主机排走 1 字 (<256) 才放行
        while (over_half) autopop;                    // 排一个即 <阈
        for (k = 0; k < PAYLOAD; k = k + 1) autopush(pat(seq_w + k));
        seq_w = seq_w + PAYLOAD;                      // used 255-1+128=383
        if (max_used !== 3 * PAYLOAD - 1) begin
            $display("%0t FAIL P1 max_used=%0d (期望 %0d)", $time, max_used, 3 * PAYLOAD - 1); $fatal;
        end
        while (!empty) autopop;                       // 全排空
        if (seq_r !== seq_w || !empty) begin
            $display("%0t FAIL P1 收平/空: sr=%0d sw=%0d", $time, seq_r, seq_w); $fatal;
        end
        $display("%0t P1 通过: credit 闸生效, 单笔途中不停, 全排空对账", $time);

        //════════ P2: 转载站慢宿主 (每 4 拍吃 1 字, 3 整包) ════════
        npp = 0; saw_credit = 0;
        while (npp < ph2_payloads || seq_r < seq_w) begin
            if (npp < ph2_payloads && over_half) saw_credit = 1;
            if (npp < ph2_payloads && !over_half) begin      // 边界 credit 闸放行 → 推整包
                for (k = 0; k < PAYLOAD; k = k + 1) autopush(pat(seq_w + k));
                seq_w = seq_w + PAYLOAD;
                npp = npp + 1;
            end else if (seq_r < seq_w) begin                // 慢宿主 4 拍一吃
                repeat (4) @(posedge clk);
                autopop;
            end else begin
                @(posedge clk);                              // 兜底推进
            end
        end
        if (!saw_credit) begin
            $display("%0t FAIL P2 慢宿主竟未触 credit", $time); $fatal;
        end
        if (seq_r !== seq_w || !empty || max_used > DEPTH) begin
            $display("%0t FAIL P2 收平/空/超容: sr=%0d sw=%0d max=%0d", $time, seq_r, seq_w, max_used); $fatal;
        end
        $display("%0t P2 通过: 慢宿主无丢, credit 中途闸, 收支平衡", $time);

        //════════ 终检 ════════
        if (seq_r !== 7 * PAYLOAD || r_ops !== 7 * PAYLOAD || w_ops !== 7 * PAYLOAD) begin
            $display("%0t FAIL 终检 seq=%0d w_ops=%0d r_ops=%0d (期望 %0d)",
                     $time, seq_r, w_ops, r_ops, 7 * PAYLOAD); $fatal;
        end
        if (!empty || full) begin
            $display("%0t FAIL 终态 empty=%b full=%b", $time, empty, full); $fatal;
        end
        $display("%0t ================= ALL PASS =================", $time);
        $display("%0t   DEPTH=%0d P=%0d 总对=%0d 峰值used=%0d", $time, DEPTH, PAYLOAD, seq_r, max_used);
        $finish;
    end

    initial begin
        #800000;
        $display("%0t FAIL global timeout", $time); $fatal;
    end
endmodule
`default_nettype wire