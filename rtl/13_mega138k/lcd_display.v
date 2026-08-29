// ============================================================================
// lcd_display.v — 800x480 RGB666 LCD 显示控制器（Tang Mega 138K Pro Dock）
//
// 复用官方 rgb_screen/800_480_screen 已验证时序参数：
//   像素时钟 35MHz（PLL: 50M x21 /1 /30）
//   H: 800 valid + 210 front + 182 back = 1192 总
//   V: 480 valid +  45 front +   8 back = 533  总
//   SYNC-DE 模式（en 作数据有效），补生成标准 hs/vs 供通用屏使用
//
// 渲染：无帧缓冲，纯组合逻辑按 (px,py) 坐标查 5x7 点阵字模。
// 显示内容：
//   Line0  GEMV STATUS
//   Line1  MODE: ACTIVE/IDLE
//   Line2  COUNT: <act_cnt hex6>
//   Line3  SUM:   <sum_out hex8>
//   引擎近期活动时底部显示滚动活动条
// ============================================================================

`timescale 1ns/1ps

module lcd_display (
    input  wire        lcd_clk,        // 35MHz
    input  wire        rst_n,          // LCD 域异步复位（PLL lock 派生）
    // ---- 显示数据（50MHz engine 域，本模块内做两级同步）----
    input  wire [23:0] act_cnt,        // 已完成 MAC 次数
    input  wire [31:0] sum_out,        // 最近一次归约结果
    input  wire        engine_busy,    // busy 指示
    // ---- 输出到屏幕 ----
    output wire        lcd_clk_o,
    output wire        lcd_en,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire [5:0]  lcd_r,
    output wire [5:0]  lcd_g,
    output wire [5:0]  lcd_b
);

    assign lcd_clk_o = lcd_clk;

    // ------------------------------------------------------------------
    // 时序参数（官方 800x480 demo）
    // ------------------------------------------------------------------
    localparam H_PIXEL_VALID = 16'd800;
    localparam H_FRONT_PORCH = 16'd210;
    localparam H_BACK_PORCH  = 16'd182;
    localparam PIXEL_FOR_HS  = H_PIXEL_VALID + H_FRONT_PORCH + H_BACK_PORCH; // 1192
    localparam V_PIXEL_VALID = 16'd480;
    localparam V_FRONT_PORCH = 16'd45;
    localparam V_BACK_PORCH  = 16'd8;
    localparam PIXEL_FOR_VS  = V_PIXEL_VALID + V_FRONT_PORCH + V_BACK_PORCH;  // 533

    localparam HS_PULSE_W = 16'd48;
    localparam VS_PULSE_W = 16'd8;

    // ------------------------------------------------------------------
    // H/V 计数器（同官方 lcd_timing）
    // ------------------------------------------------------------------
    reg [15:0] h_cnt;
    reg [15:0] v_cnt;

    always @(posedge lcd_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_cnt <= 16'b0;
            v_cnt <= 16'b0;
        end else if (h_cnt == PIXEL_FOR_HS) begin
            v_cnt <= v_cnt + 16'd1;
            h_cnt <= 16'b0;
        end else if (v_cnt == PIXEL_FOR_VS) begin
            v_cnt <= 16'b0;
            h_cnt <= 16'b0;
        end else begin
            h_cnt <= h_cnt + 16'd1;
        end
    end

    // ---- DE（数据有效，官方实现与 lcd_clk 相与）----
    assign lcd_en = (h_cnt >= H_BACK_PORCH) &&
                    (h_cnt <= H_PIXEL_VALID + H_BACK_PORCH) &&
                    (v_cnt >= V_BACK_PORCH) &&
                    (v_cnt <= V_PIXEL_VALID + V_BACK_PORCH) && lcd_clk;

    // ---- HSYNC / VSYNC（低有效脉冲）----
    assign lcd_hs = ~((h_cnt >= PIXEL_FOR_HS - HS_PULSE_W) && (h_cnt < PIXEL_FOR_HS));
    assign lcd_vs = ~((v_cnt >= PIXEL_FOR_VS - VS_PULSE_W) && (v_cnt < PIXEL_FOR_VS));

    // ------------------------------------------------------------------
    // 像素坐标（有效区内 0..799 / 0..479）
    // ------------------------------------------------------------------
    wire [9:0] px = h_cnt - H_BACK_PORCH;
    wire [9:0] py = v_cnt - V_BACK_PORCH;
    wire       in_active = (h_cnt >= H_BACK_PORCH) &&
                           (h_cnt <  H_PIXEL_VALID + H_BACK_PORCH) &&
                           (v_cnt >= V_BACK_PORCH) &&
                           (v_cnt <  V_PIXEL_VALID + V_BACK_PORCH);

    // ------------------------------------------------------------------
    // 5x7 点阵字库：font5x7(idx,row) 返回一行 5bit，bit4=最左列
    //   idx: 0..9='0'..'9' 10..15='A'..'F' 16=':' 17=' ' 18+ 见 char_idx
    // ------------------------------------------------------------------
    function [4:0] font5x7;
        input [5:0] idx;
        input [2:0] row;
        begin
            case (idx)
                0: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10011; 3: font5x7=5'b10101; 4: font5x7=5'b11001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase
                1: case (row) 0: font5x7=5'b00100; 1: font5x7=5'b01100; 2: font5x7=5'b00100; 3: font5x7=5'b00100; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase
                2: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b00001; 3: font5x7=5'b00010; 4: font5x7=5'b00100; 5: font5x7=5'b01000; 6: font5x7=5'b11111; default: font5x7=5'b0; endcase
                3: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b00010; 2: font5x7=5'b00100; 3: font5x7=5'b00010; 4: font5x7=5'b00001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase
                4: case (row) 0: font5x7=5'b00010; 1: font5x7=5'b00110; 2: font5x7=5'b01010; 3: font5x7=5'b10010; 4: font5x7=5'b11111; 5: font5x7=5'b00010; 6: font5x7=5'b00010; default: font5x7=5'b0; endcase
                5: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b10000; 2: font5x7=5'b11110; 3: font5x7=5'b00001; 4: font5x7=5'b00001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase
                6: case (row) 0: font5x7=5'b00110; 1: font5x7=5'b01000; 2: font5x7=5'b10000; 3: font5x7=5'b11110; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase
                7: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b00001; 2: font5x7=5'b00010; 3: font5x7=5'b00100; 4: font5x7=5'b01000; 5: font5x7=5'b01000; 6: font5x7=5'b01000; default: font5x7=5'b0; endcase
                8: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b01110; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase
                9: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b01111; 4: font5x7=5'b00001; 5: font5x7=5'b00010; 6: font5x7=5'b01100; default: font5x7=5'b0; endcase
               10: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b11111; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b10001; default: font5x7=5'b0; endcase  // A
               11: case (row) 0: font5x7=5'b11110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b11110; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b11110; default: font5x7=5'b0; endcase  // B
               12: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10000; 3: font5x7=5'b10000; 4: font5x7=5'b10000; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase  // C
               13: case (row) 0: font5x7=5'b11110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b10001; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b11110; default: font5x7=5'b0; endcase  // D
               14: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b10000; 2: font5x7=5'b10000; 3: font5x7=5'b11110; 4: font5x7=5'b10000; 5: font5x7=5'b10000; 6: font5x7=5'b11111; default: font5x7=5'b0; endcase  // E
               15: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b10000; 2: font5x7=5'b10000; 3: font5x7=5'b11110; 4: font5x7=5'b10000; 5: font5x7=5'b10000; 6: font5x7=5'b10000; default: font5x7=5'b0; endcase  // F
               16: case (row) 0: font5x7=5'b00000; 1: font5x7=5'b00100; 2: font5x7=5'b00100; 3: font5x7=5'b00000; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b00000; default: font5x7=5'b0; endcase  // ':'
               17: case (row) 0: font5x7=5'b00000; 1: font5x7=5'b00000; 2: font5x7=5'b00000; 3: font5x7=5'b00000; 4: font5x7=5'b00000; 5: font5x7=5'b00000; 6: font5x7=5'b00000; default: font5x7=5'b0; endcase  // ' '
               18: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10000; 3: font5x7=5'b10111; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b01111; default: font5x7=5'b0; endcase  // G
               19: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b11111; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b10001; default: font5x7=5'b0; endcase  // H
               20: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b00100; 2: font5x7=5'b00100; 3: font5x7=5'b00100; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase  // I
               21: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b10010; 2: font5x7=5'b10100; 3: font5x7=5'b11000; 4: font5x7=5'b10100; 5: font5x7=5'b10010; 6: font5x7=5'b10001; default: font5x7=5'b0; endcase  // K
               22: case (row) 0: font5x7=5'b10000; 1: font5x7=5'b10000; 2: font5x7=5'b10000; 3: font5x7=5'b10000; 4: font5x7=5'b10000; 5: font5x7=5'b10000; 6: font5x7=5'b11111; default: font5x7=5'b0; endcase  // L
               23: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b11011; 2: font5x7=5'b10101; 3: font5x7=5'b10101; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b10001; default: font5x7=5'b0; endcase  // M
               24: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b11001; 2: font5x7=5'b10101; 3: font5x7=5'b10011; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b10001; default: font5x7=5'b0; endcase  // N
               25: case (row) 0: font5x7=5'b01110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b10001; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase  // O
               26: case (row) 0: font5x7=5'b11110; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b11110; 4: font5x7=5'b10100; 5: font5x7=5'b10010; 6: font5x7=5'b10001; default: font5x7=5'b0; endcase  // R
               27: case (row) 0: font5x7=5'b01111; 1: font5x7=5'b10000; 2: font5x7=5'b10000; 3: font5x7=5'b01110; 4: font5x7=5'b00001; 5: font5x7=5'b00001; 6: font5x7=5'b11110; default: font5x7=5'b0; endcase  // S
               28: case (row) 0: font5x7=5'b11111; 1: font5x7=5'b00100; 2: font5x7=5'b00100; 3: font5x7=5'b00100; 4: font5x7=5'b00100; 5: font5x7=5'b00100; 6: font5x7=5'b00100; default: font5x7=5'b0; endcase  // T
               29: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b10001; 4: font5x7=5'b10001; 5: font5x7=5'b10001; 6: font5x7=5'b01110; default: font5x7=5'b0; endcase  // U
               30: case (row) 0: font5x7=5'b10001; 1: font5x7=5'b10001; 2: font5x7=5'b10001; 3: font5x7=5'b10001; 4: font5x7=5'b10001; 5: font5x7=5'b01010; 6: font5x7=5'b00100; default: font5x7=5'b0; endcase  // V
               default: font5x7 = 5'b00000;
            endcase
        end
    endfunction

    // 字符映射：ASCII → 字体索引
    function [5:0] char_idx;
        input [7:0] ch;
        begin
            case (ch)
                "0": char_idx = 0;  "1": char_idx = 1;  "2": char_idx = 2;  "3": char_idx = 3;
                "4": char_idx = 4;  "5": char_idx = 5;  "6": char_idx = 6;  "7": char_idx = 7;
                "8": char_idx = 8;  "9": char_idx = 9;
                "A": char_idx = 10; "B": char_idx = 11; "C": char_idx = 12; "D": char_idx = 13;
                "E": char_idx = 14; "F": char_idx = 15; "G": char_idx = 18; "H": char_idx = 19;
                "I": char_idx = 20; "K": char_idx = 21; "L": char_idx = 22; "M": char_idx = 23;
                "N": char_idx = 24; "O": char_idx = 25; "R": char_idx = 26; "S": char_idx = 27;
                "T": char_idx = 28; "U": char_idx = 29; "V": char_idx = 30;
                ":": char_idx = 16;
                default: char_idx = 17;   // 空格兜底
            endcase
        end
    endfunction

    // nibble → ASCII hex 字符
    function [7:0] hex_to_ascii;
        input [3:0] n;
        begin
            if (n < 10) hex_to_ascii = 8'd48 + n;       // '0'..'9'
            else        hex_to_ascii = 8'd65 + (n - 10); // 'A'..'F'
        end
    endfunction

    // ------------------------------------------------------------------
    // 跨时钟域：engine 50M 域 → LCD 35M 域，两级同步
    // ------------------------------------------------------------------
    reg [23:0] act_s1, act_s2;
    reg [31:0] sum_s1, sum_s2;
    reg        busy_s1, busy_s2;

    always @(posedge lcd_clk or negedge rst_n) begin
        if (!rst_n) begin
            act_s1  <= 24'b0; act_s2  <= 24'b0;
            sum_s1  <= 32'b0; sum_s2  <= 32'b0;
            busy_s1 <= 1'b0;  busy_s2 <= 1'b0;
        end else begin
            act_s1  <= act_cnt;   act_s2  <= act_s1;
            sum_s1  <= sum_out;   sum_s2  <= sum_s1;
            busy_s1 <= engine_busy; busy_s2 <= busy_s1;
        end
    end

    // 活动检测：act_s2 近期变化过 → ACTIVE（替代瞬时 busy，消除闪烁）
    reg [23:0] act_prev;
    reg [19:0] act_idle_cnt;
    wire       act_changed = (act_s2 != act_prev);
    reg        disp_active;

    always @(posedge lcd_clk or negedge rst_n) begin
        if (!rst_n) begin
            act_prev    <= 24'b0;
            act_idle_cnt<= 20'b0;
            disp_active <= 1'b0;
        end else begin
            act_prev <= act_s2;
            if (act_changed) begin
                act_idle_cnt <= 20'd0;
                disp_active  <= 1'b1;
            end else if (act_idle_cnt < 20'd2000000) begin   // ~57ms @35M
                act_idle_cnt <= act_idle_cnt + 20'd1;
            end else begin
                disp_active <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 显示文本组装
    //   Line0 "GEMV STATUS"   11 字符
    //   Line1 "MODE: xxxx"    10 字符（ACTIVE/IDLE）
    //   Line2 "COUNT: xxxxxx" 13 字符（6 hex）
    //   Line3 "SUM: xxxxxxxx" 13 字符（8 hex）
    // ------------------------------------------------------------------
    wire [7:0] line0_str [0:10];
    wire [7:0] line1_str [0:9];
    wire [7:0] line2_str [0:12];
    wire [7:0] line3_str [0:12];

    assign line0_str[0]="G"; assign line0_str[1]="E"; assign line0_str[2]="M"; assign line0_str[3]="V";
    assign line0_str[4]=" "; assign line0_str[5]="S"; assign line0_str[6]="T"; assign line0_str[7]="A";
    assign line0_str[8]="T"; assign line0_str[9]="U"; assign line0_str[10]="S";

    assign line1_str[0]="M"; assign line1_str[1]="O"; assign line1_str[2]="D"; assign line1_str[3]="E";
    assign line1_str[4]=":"; assign line1_str[5]=" ";
    assign line1_str[6]= disp_active ? "A":"I";
    assign line1_str[7]= disp_active ? "C":"D";
    assign line1_str[8]= disp_active ? "T":"L";
    assign line1_str[9]= disp_active ? "I":"E";

    assign line2_str[0]="C"; assign line2_str[1]="O"; assign line2_str[2]="U"; assign line2_str[3]="N";
    assign line2_str[4]="T"; assign line2_str[5]=":";
    assign line2_str[6] = hex_to_ascii(act_s2[23:20]);
    assign line2_str[7] = hex_to_ascii(act_s2[19:16]);
    assign line2_str[8] = hex_to_ascii(act_s2[15:12]);
    assign line2_str[9] = hex_to_ascii(act_s2[11:8]);
    assign line2_str[10]= hex_to_ascii(act_s2[7:4]);
    assign line2_str[11]= hex_to_ascii(act_s2[3:0]);
    assign line2_str[12]=" ";

    assign line3_str[0]="S"; assign line3_str[1]="U"; assign line3_str[2]="M"; assign line3_str[3]=":";
    assign line3_str[4]=" ";
    assign line3_str[5] = hex_to_ascii(sum_s2[31:28]);
    assign line3_str[6] = hex_to_ascii(sum_s2[27:24]);
    assign line3_str[7] = hex_to_ascii(sum_s2[23:20]);
    assign line3_str[8] = hex_to_ascii(sum_s2[19:16]);
    assign line3_str[9] = hex_to_ascii(sum_s2[15:12]);
    assign line3_str[10]= hex_to_ascii(sum_s2[11:8]);
    assign line3_str[11]= hex_to_ascii(sum_s2[7:4]);
    assign line3_str[12]= hex_to_ascii(sum_s2[3:0]);

    // ------------------------------------------------------------------
    // 像素着色：逐行逐字符查字模
    // ------------------------------------------------------------------
    wire [9:0] l0_x = 10'd361;  // (800 - 11*7)/2
    wire [9:0] l1_x = 10'd280;
    wire [9:0] l2_x = 10'd300;
    wire [9:0] l3_x = 10'd310;

    function glyph_on;
        input [9:0] px;
        input [9:0] py;
        input [9:0] x0;          // 字符左上角
        input [9:0] y0;
        input [7:0] ch;
        begin
            glyph_on = 1'b0;
            if (px >= x0 && px < x0 + 5 && py >= y0 && py < y0 + 7)
                glyph_on = |(font5x7(char_idx(ch), py - y0) & (5'b10000 >> (px - x0)));
        end
    endfunction

    reg  pixel_on;
    integer k;
    always @* begin
        pixel_on = 1'b0;
        if (in_active) begin
            // ---- 底部活动条（滚动）----
            if (py >= 440 && py < 460) begin
                pixel_on = ((px >> 4) & 10'd1);
            end
            // ---- Line0 标题 ----
            for (k = 0; k < 11; k = k + 1)
                if (glyph_on(px, py, l0_x + k*10'd7, 10'd60, line0_str[k]))
                    pixel_on = 1'b1;
            // ---- Line1 MODE ----
            for (k = 0; k < 10; k = k + 1)
                if (glyph_on(px, py, l1_x + k*10'd7, 10'd150, line1_str[k]))
                    pixel_on = 1'b1;
            // ---- Line2 COUNT ----
            for (k = 0; k < 13; k = k + 1)
                if (glyph_on(px, py, l2_x + k*10'd7, 10'd240, line2_str[k]))
                    pixel_on = 1'b1;
            // ---- Line3 SUM ----
            for (k = 0; k < 13; k = k + 1)
                if (glyph_on(px, py, l3_x + k*10'd7, 10'd330, line3_str[k]))
                    pixel_on = 1'b1;
        end
    end

    // 背景深蓝，文字青色，活动条绿色
    wire [5:0] fg_r = 6'b000000;
    wire [5:0] fg_g = 6'b111111;
    wire [5:0] fg_b = 6'b111111;
    wire [5:0] bar_r = 6'b000000;
    wire [5:0] bar_g = 6'b111100;
    wire [5:0] bar_b = 6'b000000;
    wire [5:0] bg_r = 6'b000000;
    wire [5:0] bg_g = 6'b000010;
    wire [5:0] bg_b = 6'b001100;
    wire       is_bar = in_active && (py >= 440 && py < 460);

    assign lcd_r = is_bar ? bar_r : pixel_on ? fg_r : bg_r;
    assign lcd_g = is_bar ? bar_g : pixel_on ? fg_g : bg_g;
    assign lcd_b = is_bar ? bar_b : pixel_on ? fg_b : bg_b;

endmodule