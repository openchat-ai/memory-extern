// ============================================================================
// tb_crc_check.v — 验证 serdes_framer_rx 的 CRC-16 检测能力
//   CASE1 正确帧 (payload 00..07, crc16=0x178D)     -> d_crc_err=0
//   CASE2 篡改 CRC 字节                            -> d_crc_err=1
//   CASE3 篡改 payload (字节4翻转, crc 仍 0x178D)  -> d_crc_err=1
// 直接喂字节流给 framer_rx, 不经过 phy/tx, 专门证明 CRC 不是摆设。
//  帧: 5A 5A lenH lenL payload(8) crcH crcL  (共 14 字节)
// ============================================================================

`timescale 1ns/1ps

module tb_crc_check;
    reg clk=0, rst_n=0;
    reg s_valid=0;
    reg [7:0] s_data=0;
    reg [7:0] mem [0:13];
    integer i;
    wire d_valid, d_done, d_crc_err;
    wire [7:0] d_data;
    integer err=0;

    serdes_framer_rx #(.MAX_LEN(512)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .s_valid(s_valid), .s_ready(), .s_data(s_data),
        .d_valid(d_valid), .d_ready(1'b1), .d_data(d_data), .d_done(d_done), .d_crc_err(d_crc_err)
    );

    always #5 clk = ~clk;

    task feed_frame();
        integer i;
        begin
            for (i=0;i<14;i=i+1) begin
                @(negedge clk); s_valid=1; s_data=mem[i];
                @(posedge clk);
            end
            @(negedge clk); s_valid=0;
        end
    endtask

    task build_frame(input [7:0] crcH, input [7:0] crcL, input integer corrupt_payload);
        begin
            mem[4]=0; mem[5]=1; mem[6]=2; mem[7]=3; mem[8]=4; mem[9]=5; mem[10]=6; mem[11]=7;
            if (corrupt_payload) mem[8]=~mem[8];   // 翻转第 5 个 payload 字节
            mem[12]=crcH; mem[13]=crcL;
        end
    endtask

    initial begin
        mem[0]=8'h5A; mem[1]=8'h5A; mem[2]=8'h00; mem[3]=8'h08;   // len=8
        #20 rst_n=1;
        @(posedge clk);

        // ---- 用例1: payload 正确, CRC 正确 (0x178D) -> 无 CRC 错误 ----
        build_frame(8'h17, 8'h8D, 0);
        feed_frame();
        if (d_crc_err === 1'b0) $display("CASE1 PASS: 正确帧 CRC 通过 (d_crc_err=0)");
        else begin $display("CASE1 FAIL: 正确帧却被判 CRC 错误"); err=err+1; end

        @(posedge clk);

        // ---- 用例2: payload 正确, CRC 字节错 -> 应报 CRC 错误 ----
        build_frame(8'h00, 8'h00, 0);
        feed_frame();
        @(posedge clk);
        if (d_crc_err === 1'b1) $display("CASE2 PASS: 篡改CRC16被检出 (d_crc_err=1)");
        else begin $display("CASE2 FAIL: 篡改CRC16未被检出"); err=err+1; end

        @(posedge clk);

        // ---- 用例3: payload 被翻转, CRC 仍 0x178D -> 应报 CRC 错误 ----
        build_frame(8'h17, 8'h8D, 1);
        feed_frame();
        @(posedge clk);
        if (d_crc_err === 1'b1) $display("CASE3 PASS: 篡改payload被检出 (d_crc_err=1)");
        else begin $display("CASE3 FAIL: 篡改payload未被检出"); err=err+1; end

        #20;
        if (err==0) $display("PASS: CRC-16 检测 3/3"); else $display("FAIL: err=%0d", err);
        $finish;
    end

endmodule
