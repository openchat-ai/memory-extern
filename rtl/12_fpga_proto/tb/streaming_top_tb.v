`timescale 1ns/1ps
module tb;
    reg clk=0, rst_n=0, start=0;
    reg nand_rd_en=0, nand_rd_valid=0;
    reg [31:0] nand_rd_data=0;

    wire busy, done, acc_valid;
    wire [31:0] acc_out, stall_cycles, tokens_done;

    streaming_top dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .busy(busy), .done(done),
        .nand_rd_en(nand_rd_en), .nand_rd_addr(nand_addr),
        .nand_rd_data(nand_rd_data), .nand_rd_valid(nand_rd_valid),
        .acc_out(acc_out), .acc_valid(acc_valid),
        .stall_cycles(stall_cycles)
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0; start = 0; nand_rd_en = 0; nand_rd_valid = 0;
        repeat(10) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        start = 1;
        repeat(200) @(posedge clk);
        start = 0;

        // 等完成
        wait(done);
        $display("[RESULT] acc=%h", acc_out);
        $finish;
    end

    initial begin
        #50000;
        $display("[TIMEOUT]");
        $finish;
    end
endmodule
