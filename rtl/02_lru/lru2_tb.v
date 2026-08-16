`timescale 1ns/1ps
module lru2_tb;
    reg clk = 0;
    reg rst_n = 0;
    reg [1:0] access = 2'b00;
    wire lru;

    lru2 dut (.clk(clk), .rst_n(rst_n), .access(access), .lru(lru));

    always #5 clk = ~clk;   // 10ns 周期时钟

    integer errors = 0;

    initial begin
        $display("=== lru2 testbench ===");

        repeat (2) @(posedge clk);   // 复位期间等 2 拍
        rst_n = 1;

        access = 2'b01;
        @(posedge clk); #1;          // #1：越过 NBA 更新窗口，读到新状态
        if (lru !== 1'b1) begin $display("FAIL: access A -> evict B (got %0d)", lru); errors = errors + 1; end
        else $display("PASS: access A -> evict B");

        access = 2'b00;
        @(posedge clk); #1;
        if (lru !== 1'b1) begin $display("FAIL: no access -> keep"); errors = errors + 1; end
        else $display("PASS: no access -> keep");

        access = 2'b10;
        @(posedge clk); #1;
        if (lru !== 1'b0) begin $display("FAIL: access B -> evict A (got %0d)", lru); errors = errors + 1; end
        else $display("PASS: access B -> evict A");

        access = 2'b01;
        @(posedge clk); #1;
        if (lru !== 1'b1) begin $display("FAIL: access A again -> evict B (got %0d)", lru); errors = errors + 1; end
        else $display("PASS: access A again -> evict B");

        // 复位：先清掉挂着的输入，否则复位一释放，挂在边沿的访问 A 会被消费
        rst_n = 0;
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst_n = 1;
        access = 2'b00;
        @(posedge clk); #1;
        if (lru !== 1'b0) begin $display("FAIL: reset -> evict A (got %0d)", lru); errors = errors + 1; end
        else $display("PASS: reset -> evict A");

        if (errors === 0) $display("=== ALL PASS ===");
        else $display("=== %0d ERROR(S) ===", errors);
        $finish;
    end
endmodule
