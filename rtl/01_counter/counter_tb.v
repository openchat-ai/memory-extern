`timescale 1ns/1ps
module counter_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg en = 0;
    wire [3:0] count;

    counter dut (.clk(clk), .rst_n(rst_n), .en(en), .count(count));

    always #5 clk = ~clk;           // 周期 10ns 的时钟

    integer errors = 0;

    initial begin
        $display("=== counter testbench ===");
        repeat (2) @(posedge clk);   // 复位期间等 2 拍
        rst_n = 1;
        en = 1;
        repeat (4) @(posedge clk);   // 使能 4 拍 → count 应为 4
        if (count !== 4'd4) begin
            $display("FAIL: expected 4, got %0d", count);
            errors = errors + 1;
        end else
            $display("PASS: count=%0d after 4 enabled clocks", count);

        en = 0;
        repeat (3) @(posedge clk);   // 停使能 3 拍 → count 应冻结
        if (count !== 4'd4) begin
            $display("FAIL: count changed while disabled");
            errors = errors + 1;
        end else
            $display("PASS: count frozen at %0d while disabled", count);

        // 复位测试：置低再释放，应归零
        rst_n = 0;
        @(posedge clk);
        @(posedge clk);
        rst_n = 1;
        if (count !== 4'd0) begin
            $display("FAIL: reset did not clear count");
            errors = errors + 1;
        end else
            $display("PASS: reset clears count");

        if (errors === 0)
            $display("=== ALL PASS ===");
        else
            $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
