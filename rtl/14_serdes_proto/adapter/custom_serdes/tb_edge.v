// ============================================================================
// tb_edge.v — 多 lane serdes_link 边界扫描
//   对 (N_LANE, BIT_DELAY, RX_DEPTH) 组合做数据完整性 + 背压抖动验证。
//   harness: 标准 AXI valid 保持(每字节恰交付一次); out_ready 用
//     3收2停 模式(抖动背压), 校验输出与输入严格同序。
//   覆盖:
//     N=1            退化(等于单链路)
//     N=2 / 4 / 8    不同 lane 宽
//     BIT_DELAY 2/7  链路延迟边界(最小合法值=2, 因为延迟链需要 >=1 级移位)
//     RX_DEPTH 2/4   最小 FIFO 深度边界(RX_DEPTH>=2 即可用)
// ============================================================================

`timescale 1ns/1ps

module edge_harness #(
    parameter N_LANE    = 4,
    parameter BIT_DELAY = 3,
    parameter RX_DEPTH  = 16,
    parameter NBYTE     = 320
)();
    reg clk = 0, rst_n = 0;
    reg in_valid = 0, out_ready = 1;
    reg [7:0] in_data = 0;
    reg [1:0] rdy_cnt = 0;          // 背压抖动: 3 收 2 停
    wire in_ready, out_valid;
    wire [7:0] out_data;

    integer sent = 0, rcvd = 0, err = 0;
    reg done = 0;

    always #5 clk = ~clk;

    serdes_link #(.DATAW(8), .N_LANE(N_LANE),
                  .BIT_DELAY(BIT_DELAY), .RX_DEPTH(RX_DEPTH)) u_link (
        .clk(clk), .rst_n(rst_n),
        .in_ready(in_ready), .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data));

    // out_ready 抖动: 每周期先收 3 拍再停 2 拍
    always @(posedge clk) begin
        if (!rst_n) begin rdy_cnt <= 0; out_ready <= 1; end
        else begin
            rdy_cnt <= rdy_cnt + 2'd1;
            if (rdy_cnt == 2'd2)      out_ready <= 1'b0;
            else if (rdy_cnt == 2'd3) out_ready <= 1'b1;
        end
    end
    // 周期 0,1 收; 2,3 停(实际 0..3 四拍内 0,1 收 2,3 停), 交替 —— 约 3收2停

    // producer: AXI valid 保持
    always @(posedge clk) begin
        if (!rst_n) begin sent <= 0; in_valid <= 0; in_data <= 0; end
        else if (in_ready && in_valid) begin
            in_valid <= 0;
            sent     <= sent + 1;
        end else if (!in_valid && sent < NBYTE) begin
            in_data  <= sent[7:0];
            in_valid <= 1;
        end
    end

    // consumer: 校验
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (out_data !== rcvd[7:0]) begin
                err <= err + 1;
                $display("  edge(N=%0d,BD=%0d,RX=%0d) MISMATCH @%0t got %h exp %h",
                         N_LANE, BIT_DELAY, RX_DEPTH, $time, out_data, rcvd[7:0]);
            end
            rcvd <= rcvd + 1;
        end
        if (rst_n && rcvd >= NBYTE && !done) done <= 1;
    end

    initial begin
        #15 rst_n = 1;
        while (!done) #20;
        #500;
        if (err == 0 && rcvd == NBYTE)
            $display("PASS: edge N=%0d BIT_DELAY=%0d RX_DEPTH=%0d  %0d 字节背压抖动下完整同序",
                     N_LANE, BIT_DELAY, RX_DEPTH, NBYTE);
        else
            $display("FAIL: edge N=%0d BIT_DELAY=%0d RX_DEPTH=%0d  rcvd=%0d err=%0d",
                     N_LANE, BIT_DELAY, RX_DEPTH, rcvd, err);
    end
endmodule

module tb_edge;
    // 各组实例: (N, BIT_DELAY, RX_DEPTH, NBYTE)
    edge_harness #(.N_LANE(1),  .BIT_DELAY(3), .RX_DEPTH(16), .NBYTE(256)) h_n1  ();
    edge_harness #(.N_LANE(2),  .BIT_DELAY(3), .RX_DEPTH(16), .NBYTE(320)) h_n2  ();
    edge_harness #(.N_LANE(4),  .BIT_DELAY(3), .RX_DEPTH(16), .NBYTE(320)) h_n4  ();
    edge_harness #(.N_LANE(8),  .BIT_DELAY(3), .RX_DEPTH(16), .NBYTE(512)) h_n8  ();
    edge_harness #(.N_LANE(4),  .BIT_DELAY(2), .RX_DEPTH(16), .NBYTE(320)) h_bd1 ();
    edge_harness #(.N_LANE(4),  .BIT_DELAY(7), .RX_DEPTH(16), .NBYTE(320)) h_bd7 ();
    edge_harness #(.N_LANE(4),  .BIT_DELAY(3), .RX_DEPTH(2),  .NBYTE(320)) h_rx2 ();
    edge_harness #(.N_LANE(4),  .BIT_DELAY(3), .RX_DEPTH(4),  .NBYTE(320)) h_rx4 ();

    // 汇总结论: 等所有 harness done
    integer all_done;
    initial begin
        all_done = 0;
        while (h_n1.done + h_n2.done + h_n4.done + h_n8.done +
               h_bd1.done + h_bd7.done + h_rx2.done + h_rx4.done < 8) #50;
        #500;
        if (h_n1.err == 0 && h_n2.err == 0 && h_n4.err == 0 && h_n8.err == 0 &&
            h_bd1.err == 0 && h_bd7.err == 0 && h_rx2.err == 0 && h_rx4.err == 0 &&
            h_n1.rcvd==256 && h_n2.rcvd==320 && h_n4.rcvd==320 && h_n8.rcvd==512 &&
            h_bd1.rcvd==320 && h_bd7.rcvd==320 && h_rx2.rcvd==320 && h_rx4.rcvd==320)
            $display("PASS: 边界扫描 8 组 (N=1/2/4/8, BIT_DELAY=2/3/7, RX_DEPTH=2/4/16) 全部完整同序");
        else
            $display("FAIL: 边界扫描 有 harness 未通过");
        $finish;
    end
endmodule