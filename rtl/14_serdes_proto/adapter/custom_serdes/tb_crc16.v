// ============================================================================
// tb_crc16.v — CRC-16-CCITT 标准向量验证
//   "123456789" 依序喂入 crc16, 结果应为 0x29B1 (标准 CRC-16-CCITT/FALSE 向量)。
//   init=0xFFFF, poly=0x1021。
// ============================================================================

`timescale 1ns/1ps

module tb_crc16;
    reg clk=0, rst_n=0, crc_en=0, crc_init=0;
    reg [7:0] crc_din=0;
    reg [7:0] mem [0:8];
    wire [15:0] crc_out;
    integer i;
    always #5 clk = ~clk;

    crc16 u (.clk(clk), .rst_n(rst_n), .crc_en(crc_en), .crc_din(crc_din), .crc_init(crc_init), .crc_out(crc_out));

    task feed(input [7:0] d);
        begin
            @(negedge clk); crc_din=d; crc_en=1;
            @(posedge clk);
            @(negedge clk); crc_en=0;
        end
    endtask

    initial begin
        mem[0]="1"; mem[1]="2"; mem[2]="3"; mem[3]="4"; mem[4]="5";
        mem[5]="6"; mem[6]="7"; mem[7]="8"; mem[8]="9";
        #20 rst_n=1;
        @(posedge clk); crc_init=1;
        @(posedge clk);
        @(negedge clk); crc_init=0;
        for (i=0;i<9;i=i+1) feed(mem[i]);
        #20;
        if (crc_out !== 16'h29B1) $display("FAIL: crc=%h expect 29B1", crc_out);
        else $display("PASS: CRC-16-CCITT 123456789 = 29B1 (标准向量)");
        $finish;
    end
endmodule
