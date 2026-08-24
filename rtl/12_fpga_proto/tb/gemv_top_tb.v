`timescale 1ns/1ps
module gemv_top_tb;
    reg clk=0, rst_n=0;
    reg wt_valid=0, result_valid_w=0;
    reg [15:0] wt_packed=0; reg [7:0] wt_scale=127; reg [15:0] act_vec_in=16'h3F80; // act=1.0

    wire result_valid;
    wire [15:0] rw0, rw1, rw2, rw3;

    // E2M1 查表参考值（bf16）
    function [15:0] e2m1_ref;
        input [3:0] c;
        case (c[2:0])
            3'b000: e2m1_ref = 16'h0000; // 0.0
            3'b001: e2m1_ref = 16'h3F00; // 0.5
            3'b010: e2m1_ref = 16'h3F80; // 1.0
            3'b011: e2m1_ref = 16'h3FC0; // 1.5
            3'b100: e2m1_ref = 16'h4000; // 2.0
            3'b101: e2m1_ref = 16'h4040; // 3.0
            3'b110: e2m1_ref = 16'h4080; // 4.0
            3'b111: e2m1_ref = 16'h40E0; // 6.0
        endcase
        if (c[3]) e2m1_ref[15] = 1;
    endfunction

    gemv_top dut (
        .clk(clk), .rst_n(rst_n),
        .wt_valid(wt_valid), .wt_packed(wt_packed),
        .wt_scale(wt_scale), .act_vec_in(act_vec_in),
        .result_valid(result_valid),
        .result_w0(rw0), .result_w1(rw1), .result_w2(rw2), .result_w3(rw3)
    );

    always #5 clk = ~clk;

    integer errors = 0;

    initial begin
        rst_n = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // 测试：scale=127(即无偏移)，输入 E2M1 码 0b0011 = 1.5
        wt_scale = 127;
        wt_packed = 16'h3333; // 4×code 0011 → 全部 1.5
        wt_valid = 1;
        @(posedge clk);
        wt_valid = 0;
        repeat(3) @(posedge clk); // 等流水线

        $display("[TEST] MXFP4 解包验证");
        $display("  输入 packed = %h (期望全为 code=0011 → bf16 1.5)", 16'h3333);
        if (rw0 === 16'h3FC0)
            $display("  PASS: w0=%h (=bf16 1.5) ✅", rw0);
        else
            $display("  FAIL: w0=%h (期望 3FC0) ❌", rw0);

        // 测试不同码
        wt_packed = 16'h4000; // codes: 0100 0000 → +2.0 和 0.0
        wt_valid = 1;
        @(posedge clk);
        wt_valid = 0;
        repeat(3) @(posedge clk);

        $display("  输入 packed = %h", 16'h4000);
        $display("  w0=%h w1=%h", rw0, rw1);

        $display("\n[ALL TESTS DONE] errors=%0d", errors);
        $finish;
    end
endmodule
