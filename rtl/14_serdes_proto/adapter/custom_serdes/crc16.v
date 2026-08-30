// ============================================================================
// crc16.v — CRC-16-CCITT/FALSE (poly 0x1021, 初值 0xFFFF, MSB-first, 不反射)
// 面向字节流: 依序处理每个字节, 产出一个 16bit 校验值。
// MSB-first 与现有 SerDes 字节流方向一致, 直接替换 crc8 即可。
// 标准向量: "123456789" -> 0x29B1
// ============================================================================

`timescale 1ns/1ps

module crc16 #(
    parameter [15:0] POLY  = 16'h1021,
    parameter [15:0] INIT  = 16'hFFFF
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        crc_en,     // 处理一个字节的使能(拍级)
    input  wire [7:0]  crc_din,    // 输入字节
    input  wire        crc_init,   // 初始化为初值
    output reg  [15:0] crc_out
);

    reg [15:0] nxt;
    integer b;

    always @(posedge clk) begin
        if (!rst_n)
            crc_out <= INIT;
        else if (crc_init)
            crc_out <= INIT;
        else if (crc_en) begin
            nxt = crc_out ^ ({crc_din, 8'h00});
            for (b = 0; b < 8; b = b + 1) begin
                nxt = (nxt[15]) ? ({nxt[14:0], 1'b0} ^ POLY) : {nxt[14:0], 1'b0};
            end
            crc_out <= nxt;
        end
    end

endmodule
