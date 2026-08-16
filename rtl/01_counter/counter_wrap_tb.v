`timescale 1ns/1ps
module counter_wrap_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    wire [11:0] count;

    counter dut (.clk(clk), .rst_n(rst_n), .en(en), .count(count));

    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        $display("=== counter wrap testbench ===");
        repeat (2) @(posedge clk);
        rst_n = 1;
        en = 1;
        repeat (1001) @(posedge clk);   // 从 0 数 1001 拍：到 1000 应归零，再走 1 拍 = 1
        if (count !== 12'd0) begin
            $display("FAIL: expected wrap to 0 at 1000, got %0d", count);
            errors = errors + 1;
        end else
            $display("PASS: count wrapped to 0 at 1000");

        repeat (5) @(posedge clk);      // 继续 5 拍
        if (count !== 12'd5) begin
            $display("FAIL: expected 5 after 1005 clocks, got %0d", count);
            errors = errors + 1;
        end else
            $display("PASS: count = 5 after 1005 clocks");

        if (errors === 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
