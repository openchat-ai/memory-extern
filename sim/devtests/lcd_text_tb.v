`timescale 1ps/1ps
// lcd_text_tb — lcd_display 的**文字层**回归 (2026-10-22)
// 起因: 板级实测发现屏上显示 ":S F" 而不是 "DECODE STATUS / FPS: ..." ——
//   把字符逐个显式赋值改成"字符串参数打包"时, Verilog 字符串首字符在最高位,
//   而解包从最低位取 → 整行反着画。iverilog 不查这个, 只有真机能看出来。
//   → 文字层必须有独立 TB (像素级太重, 这里直接查驱动内部的字符数组)。
//
// 判据: 标题逐字符 = "DECODE STATUS"; 每行标签逐字符 = 传入的字符串;
//       十六进制位 = 值的十六进制 (高位在前)。
module lcd_text_tb;
    localparam integer SC = 6;
    reg clk = 0, rst_n = 0;
    wire lcd_clk_o, lcd_en, lcd_hs, lcd_vs;
    wire [5:0] lcd_r, lcd_g, lcd_b;
    integer i, errors;

    lcd_display #(
        .TITLE   ("DECODE STATUS"),
        .LBL1    ("FPS:  "),
        .LBL2    ("W:    "),
        .LBL3    ("HASH: "),
        .LBL4    ("FRM:  "),
        .LBL5    ("L:    "),
        .L1_WORD (1'b0),
        .NLINES  (6),
        .SCALE   (SC)
    ) U (
        .lcd_clk (clk), .rst_n (rst_n),
        .act_cnt (24'd1234), .cnt1 (24'd128), .cnt2 (24'd24430),
        .val8 (32'hADE40FB3), .cnt4 (24'd128160), .cnt5 (24'd3),
        .lcd_clk_o (lcd_clk_o), .lcd_en (lcd_en), .lcd_hs (lcd_hs), .lcd_vs (lcd_vs),
        .lcd_r (lcd_r), .lcd_g (lcd_g), .lcd_b (lcd_b)
    );

    always #5 clk = ~clk;

    reg [8*11-1:0] exp_title;
    reg [8*7-1:0]  exp_lbl [0:4];
    reg [8*8-1:0]  exp_hex [0:4];

    initial begin
        errors = 0;
        exp_title = "DECODE STATUS";
        exp_lbl[0] = "FPS:  ";
        exp_lbl[1] = "W:    ";
        exp_lbl[2] = "HASH: ";
        exp_lbl[3] = "FRM:  ";
        exp_lbl[4] = "L:    ";
        exp_hex[0] = "00005F6E";   // 24430
        exp_hex[1] = "00000080";   // 128
        exp_hex[2] = "ADE40FB3";
        exp_hex[3] = "0001F4A0";   // 128160
        exp_hex[4] = "00000003";   // 3

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        // 标题逐字符
        for (i = 0; i < 11; i = i + 1) begin
            if (U.t0_str[i] !== exp_title[8*(10-i) +: 8]) begin
                $display("FAIL 标题第 %0d 字符: 期望 %c 实得 %c",
                         i, exp_title[8*(10-i) +: 8], U.t0_str[i]);
                errors = errors + 1;
            end
        end
        // 标签 + 十六进制位
        for (i = 0; i < 5; i = i + 1) begin
            for (i2 = 0; i2 < 7; i2 = i2 + 1) begin
                if (U.d_str[i][i2] !== exp_lbl[i][8*(6-i2) +: 8]) begin
                    $display("FAIL 行%0d 标签第 %0d 字符: 期望 %c 实得 %c",
                             i, i2, exp_lbl[i][8*(6-i2) +: 8], U.d_str[i][i2]);
                    errors = errors + 1;
                end
            end
            for (i2 = 0; i2 < 8; i2 = i2 + 1) begin
                if (U.d_str[i][7+i2] !== exp_hex[i][8*(7-i2) +: 8]) begin
                    $display("FAIL 行%0d 十六进制第 %0d 位: 期望 %c 实得 %c",
                             i, i2, exp_hex[i][8*(7-i2) +: 8], U.d_str[i][7+i2]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0) $display("lcd_text PASS (标题/标签/十六进制全部逐字符正确)");
        else $display("lcd_text FAIL errors=%0d", errors);
        $finish;
    end
    integer i2;
endmodule
