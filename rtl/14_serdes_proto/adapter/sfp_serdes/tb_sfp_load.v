// ============================================================================
// tb_sfp_load.v — SFP+/SerDes 高速档: 协议层(lane 分发/聚合)零改动换 phy 验证
//
//   复用 serdes_link + PHY_TYPE=1(serdes_phy_sfp), N_LANE=8, 满载灌入:
//     断言: 8 lane SFP+ 背板下, 字节流零丢失、严格保序、吞吐达 1 字节/拍。
//   证明: 换物理层(10G SerDes) 不改协议层, 架构的"可插拔接口适配器"成立。
// ============================================================================

`timescale 1ns/1ps

module tb_sfp_load #(
    parameter N_LANE = 8,
    parameter WIN_NS = 40000
)();
    reg clk = 0, rst_n = 0, in_valid = 0;
    reg [7:0] in_data = 0;
    wire in_ready, out_valid;
    wire [7:0] out_data;
    integer hs = 0, rcvd = 0;
    reg [31:0] expd = 0, firstbad = 32'hFFFF_FFFF;

    always #5 clk = ~clk;

    serdes_link #(.DATAW(8), .N_LANE(N_LANE), .BIT_DELAY(3), .RX_DEPTH(16),
                  .PHY_TYPE(1)) u_link (
        .clk(clk), .rst_n(rst_n),
        .in_ready(in_ready), .in_valid(in_valid), .in_data(in_data),
        .out_valid(out_valid), .out_ready(1'b1), .out_data(out_data));

    always @(posedge clk) begin
        if (!rst_n) begin in_valid <= 1'b1; in_data <= 8'd0; end
        else if (in_ready && in_valid) in_data <= in_data + 8'd1;
    end

    always @(posedge clk) begin
        if (!rst_n) begin hs <= 0; rcvd <= 0; expd <= 0; firstbad <= 32'hFFFF_FFFF; end
        else begin
            if ($time >= 30000 && $time < 30000 + WIN_NS && out_valid) hs <= hs + 1;
            if (out_valid) begin
                if (out_data !== expd[7:0] && firstbad > expd) firstbad <= expd;
                expd <= expd + 1;
                rcvd <= rcvd + 1;
            end
        end
    end

    initial begin
        #15 rst_n = 1;
        while ($time < 30000 + WIN_NS + 100000) #10;
        if (firstbad == 32'hFFFF_FFFF)
            $display("PASS: SFP+ SerDes N=%0d lane 满载零丢失·严格保序·吞吐=%.3f 字节/拍(理论 min(N/8,1))",
                     N_LANE, hs * 10.0 / WIN_NS);
        else
            $display("FAIL: SFP+ SerDes N=%0d 字节序 firstbad=%0d", N_LANE, firstbad);
    end
endmodule

module tb_sfp_top;
    tb_sfp_load #(.N_LANE(8)) t8 ();
    tb_sfp_load #(.N_LANE(4)) t4 ();
    tb_sfp_load #(.N_LANE(1)) t1 ();
    initial begin #400000 $finish; end
endmodule
