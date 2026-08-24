`timescale 1ns/1ps
module tb;
    reg clk=0, rst_n=0, start=0, wt_valid=0;
    reg [31:0] wt_data=0; reg [7:0] wt_scale=127;
    reg [31:0] total_w=32;
    wire wt_ready, busy, result_valid;
    wire [31:0] result, tokens_done;

    gemv_engine dut(.clk(clk),.rst_n(rst_n),
        .wt_valid(wt_valid),.wt_data(wt_data),.wt_scale(wt_scale),.wt_ready(),
        .start(start),.total_weights(total_w),
        .busy(busy),.result(result),.result_valid(result_valid),.tokens_done(tokens_done));

    always #5 clk=~clk;

    integer i;
    initial begin
        rst_n=0; repeat(10) @(posedge clk); rst_n=1;
        repeat(5) @(posedge clk);

        // 发送 4 个 32bit 权重包（共 32 个权重）
        start = 1;
        for(i=0;i<4;i=i+1) begin
            wt_valid=1; wt_data = 32'h11111111 * (i+1);
            @(posedge clk);
        end
        wt_valid=0; start=0;

        // 等完成
        wait(result_valid);
        $display("[PASS] result=%h tokens=%0d", result, tokens_done);
        $finish;
    end

    initial begin #50000; $display("[TIMEOUT]"); $finish; end
endmodule
