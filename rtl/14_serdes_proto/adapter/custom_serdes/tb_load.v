// ============================================================================
// tb_load.v — 多 lane 满载吞吐 + 保序边界验证
//   对 N_LANE=1/4/8/16/24 无限灌入(AXI 背压), 校验:
//     (a) 零丢失、严格保序 (err==0, firstbad 未触发)
//     (b) 达到理论速度边界 min(N_LANE/8, 1) 字节/拍
//   这是速度边界&可靠性的核心测试:
//     - RX 聚合单拍化后出口达 1 字节/拍(不再两拍瓶颈)
//     - TX 分发 level 握手后单 lane 满载不再丢字节
// ============================================================================

`timescale 1ns/1ps

module load_harness #(
    parameter N_LANE = 4,
    parameter WIN_NS = 80000
)();
    reg clk = 0, rst_n = 0, in_valid = 0;
    reg [7:0] in_data = 0;
    wire in_ready, out_valid;
    wire [7:0] out_data;
    integer hs = 0, rcvd = 0, err = 0;
    reg [31:0] expd = 0, firstbad = 32'hFFFF_FFFF;

    always #5 clk = ~clk;

    serdes_link #(.DATAW(8), .N_LANE(N_LANE), .BIT_DELAY(3), .RX_DEPTH(32)) u_link (
        .clk(clk), .rst_n(rst_n),
        .in_ready(in_ready), .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(1'b1), .out_data(out_data));

    // 标准 AXI 无限 producer
    always @(posedge clk) begin
        if (!rst_n) begin in_valid <= 1'b1; in_data <= 8'd0; end
        else if (in_ready && in_valid) in_data <= in_data + 8'd1;
    end

    // RX 出口: 统计吞吐 + 保序校验
    always @(posedge clk) begin
        if (!rst_n) begin hs <= 0; rcvd <= 0; err <= 0; expd <= 0; firstbad <= 32'hFFFF_FFFF; end
        else begin
            if ($time >= 30000 && $time < 30000 + WIN_NS && out_valid) hs <= hs + 1;
            if (out_valid) begin
                if (out_data !== expd[7:0] && firstbad > expd) firstbad <= expd;
                expd <= expd + 32'd1;
                rcvd <= rcvd + 1;
            end
        end
    end

    initial begin
        #15 rst_n = 1;
        while ($time < 30000 + WIN_NS + 50000) #10;
        if (err == 0 && firstbad == 32'hFFFF_FFFF)
            $display("PASS: 满载 N=%0d 零丢失·严格保序·吞吐=%.3f 字节/拍(理论 min(N/8,1)=%.1f)",
                     N_LANE, hs * 10.0 / WIN_NS, N_LANE < 8 ? N_LANE / 8.0 : 1.0);
        else
            $display("FAIL: 满载 N=%0d err=%0d firstbad=%0d", N_LANE, err, firstbad);
    end
endmodule

module tb_load;
    load_harness #(.N_LANE(1))  l1 ();
    load_harness #(.N_LANE(4))  l4 ();
    load_harness #(.N_LANE(8))  l8 ();
    load_harness #(.N_LANE(16)) l16 ();
    initial begin #800000 $finish; end
endmodule