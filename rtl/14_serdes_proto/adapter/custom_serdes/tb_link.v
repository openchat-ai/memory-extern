// ============================================================================
// tb_link.v — 验证 serdes_link 多 lane 聚合保序正确
//   N_LANE=4 条独立 lane, 上层字节流 0..N-1 经 round-robin 分发 -> 各 lane
//   独立回环 -> round-robin 聚合还原。验证: 输出顺序 == 输入顺序。
//
// 注意: 分发只保序, 吞吐提升在帧层面体现; 本测试专注"不丢、不乱序"。
// ============================================================================

`timescale 1ns/1ps

module tb_link;
    parameter DATAW  = 8;
    parameter N_LANE = 4;
    parameter NBYTE  = 160;

    reg clk=0, rst_n=0, in_valid=0, out_ready=1;
    reg [7:0] in_data=0;
    wire in_ready, out_valid;
    wire [7:0] out_data;

    integer sent=0, rcvd=0, err=0;

    always #5 clk = ~clk;

    serdes_link #(.DATAW(DATAW), .N_LANE(N_LANE), .BIT_DELAY(3), .RX_DEPTH(16)) u_link (
        .clk(clk), .rst_n(rst_n),
        .in_ready(in_ready), .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data));

    // TX 源: 标准 AXI valid/ready —— valid 拉高即保持直到握手, 每字节恰交付一次
    always @(posedge clk) begin
        if (!rst_n) begin sent<=0; in_valid<=0; in_data<=0; end
        else if (in_ready && in_valid) begin
            in_valid <= 0;                 // 握手成功, 撤销 valid(下一拍载入下一)
            sent     <= sent + 1;
        end else if (!in_valid && sent < NBYTE) begin
            in_data  <= sent[7:0];
            in_valid <= 1;
        end
    end

    // RX 校验: 输出必须 = 0,1,2,...
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (out_data !== rcvd[7:0]) begin
                $display("MISMATCH @%0t: got %h exp %h", $time, out_data, rcvd[7:0]);
                err<=err+1;
            end
            rcvd<=rcvd+1;
            if (rcvd%40==0) $display("@%0t rcvd=%0d ok", $time, rcvd);
        end
    end

    initial begin
        #20 rst_n=1;
        while (rcvd < NBYTE) #50;
        #300;
        if (err==0 && rcvd==NBYTE) $display("PASS: 多lane(%0d) 聚合 %0d 字节无丢失、顺序正确", N_LANE, NBYTE);
        else $display("FAIL: rcvd=%0d err=%0d", rcvd, err);
        $finish;
    end
endmodule
