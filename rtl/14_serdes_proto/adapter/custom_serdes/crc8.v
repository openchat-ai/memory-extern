// ============================================================================
// crc8.v — CRC-8 (poly 0x07, 初值 0x00, MSB-first, 不反射, 不对末值取反)
// 面向字节流: 依序处理每个字节, 产出一个 8bit 校验值。
// 算法 = 标准 CRC-8/ATM: 每个字节先整体异或进寄存器, 再逐位左移。
// 标准向量: "123456789" -> 0xF4
// ============================================================================

`timescale 1ns/1ps

module crc8 #(
    parameter [7:0] POLY = 8'h07
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        crc_en,     // 处理一个字节的使能(拍级)
    input  wire [7:0]  crc_din,    // 输入字节
    input  wire        crc_init,   // 初始化为初值
    output reg  [7:0]  crc_out
);

    reg [7:0] nxt;
    integer b;

    always @(posedge clk) begin
        if (!rst_n)
            crc_out <= 8'h00;
        else if (crc_init)
            crc_out <= 8'h00;
        else if (crc_en) begin
            nxt = crc_out ^ crc_din;
            for (b = 0; b < 8; b = b + 1) begin
                nxt = (nxt[7]) ? ({nxt[6:0], 1'b0} ^ POLY) : {nxt[6:0], 1'b0};
            end
            crc_out <= nxt;
        end
    end

endmodule
