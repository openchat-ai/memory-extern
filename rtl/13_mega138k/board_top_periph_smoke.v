// ============================================================================
// board_top_periph_smoke.v — 全外设冒烟：引擎 + WS2812 + 按键 + RGB LCD
//
// 目的：在 macsplit_reg 引擎冒烟通过（124.3MHz，LED心跳+引擎活动）基础上，
// 把板载外设一次性全部点亮验证：
//   1. 引擎（LED[3:0] 心跳 + 活动）——已验证基线
//   2. WS2812（H16）单 LED 颜色循环（官方算法，跑 50MHz sys_clk）
//   3. 按键 S1/F15、S2/G15、S3/G16 —— 反映到 LED[4:5] 与 WS2812 开关
//   4. RGB LCD（480x272，RGB565 6bit，彩条 + DE），像素时钟 200MHz÷20=10MHz
//
// 时钟规划：
//   sys_clk(P16 50MHz) → Gowin_PLL_X200 → clk_int(200MHz)：
//      引擎 + LCD 分频(10MHz)
//   sys_clk(50MHz) 直驱 WS2812（官方参数 CLK_FRE=50MHz）
// ============================================================================
`timescale 1ns/1ps

module board_top_periph_smoke (
    input  wire sys_clk,          // P16 板载 50MHz 振荡器
    input  wire rst_n,            // S0（K16）复位按键，低有效
    input  wire key1,             // S1（F15）
    input  wire key2,             // S2（G15）
    input  wire key3,             // S3（G16）
    output wire [5:0] led,        // LED[0..5] 共阳极低亮
    output wire WS2812,           // H16 RGB LED

    // RGB LCD（480x272，RGB565）
    output wire lcd_clk,          // H21 像素时钟 10MHz
    output wire lcd_en,           // A24 DE
    output wire [5:0] lcd_r,      // H19 K17...
    output wire [5:0] lcd_g,      // J16 K15...
    output wire [5:0] lcd_b       // F20 M16...
);

    localparam NUM_LANES = 128;

    // ---------------- 时钟：PLL 200MHz ----------------
    wire clk_200m;
    wire pll200_lock;
    Gowin_PLL_X200 u_pll200 (
        .clkout0 (clk_200m),
        .lock    (pll200_lock),
        .clkin   (sys_clk)
    );
    wire clk_int = clk_200m;

    // ---------------- 复位同步（200MHz 域）----------------
    reg [15:0] por_cnt;
    reg        rst_meta;
    reg        rst_sync;
    wire       por_done = (por_cnt == 16'd0);
    wire       rst_n_int = rst_sync;
    wire       rst_n_core = rst_sync & pll200_lock;
    initial begin
        por_cnt  = 16'hFFFF;
        rst_meta = 1'b1;
        rst_sync = 1'b1;
    end
    always @(posedge clk_int) begin
        if (!por_done)
            por_cnt <= por_cnt - 16'd1;
        rst_meta <= rst_n & por_done;
        rst_sync <= rst_meta;
    end

    // ---------------- LED 心跳 + 引擎活动（200MHz 域）----------------
    reg [26:0] hb_cnt;
    always @(posedge clk_int) begin
        if (!rst_n_core)  hb_cnt <= 27'd0;
        else              hb_cnt <= hb_cnt + 27'd1;
    end

    assign led[0] = hb_cnt[26];
    assign led[1] = sum_valid | hb_cnt[15];
    assign led[2] = sum_out[0] | hb_cnt[16];
    assign led[3] = (|sum_out[31:1]) ? 1'b0 : hb_cnt[17];
    // 按键反映（共阳极低亮；上啦未按=1，按钮按下=0 → LED 亮）
    assign led[4] = ~key1;
    assign led[5] = ~key2;

    // ---- 引擎输入驱动 ----
    localparam WT_BITS = NUM_LANES * 4;
    localparam X_BITS  = NUM_LANES * 8;
    wire [WT_BITS-1:0] wt_drv;
    wire [X_BITS-1:0]  x_drv;
    genvar gi;
    generate
        if (WT_BITS > 0) begin : g_wt
            for (gi = 0; gi < WT_BITS; gi = gi + 1) begin : wtb
                assign wt_drv[gi] = hb_cnt[gi % 27];
            end
        end
        if (X_BITS > 0) begin : g_x
            for (gi = 0; gi < X_BITS; gi = gi + 1) begin : xb
                assign x_drv[gi] = ~hb_cnt[(gi + 13) % 27];
            end
        end
    endgenerate

    wire [31:0] sum_out;
    wire        sum_valid;
    wire        busy;

    engine_core_macsplit_reg #(
        .NUM_LANES  (NUM_LANES),
        .ACC_WIDTH  (32),
        .HALF_LANES (64)
    ) u_engine (
        .clk       (clk_int),
        .rst_n     (rst_n_core),
        .wt_valid  (hb_cnt[0]),
        .wt_data   (wt_drv),
        .x_data    (x_drv),
        .x_valid   (hb_cnt[1]),
        .acc_clr   (1'b0),
        .sum_out   (sum_out),
        .sum_valid (sum_valid),
        .busy      (busy)
    );

    // ---------------- LCD：35MHz PLL + 800x480 RGB666 彩条时序 ----------------
    // 板上是 800x480 Dock RGB666 屏（lcd_display.v 已验证：H=800+210+182=1192, V=480+45+8=533, 35MHz）
    // 先前误用 480x272 @10MHz 导致彩条只占 2/3 宽度；此处改回已验证时序
    wire lcd_clk_35;
    wire pll_lock;
    Gowin_PLL u_pll (
        .clkout0 (lcd_clk_35),
        .lock    (pll_lock),
        .clkin   (sys_clk)
    );
    wire lcd_pix_clk = lcd_clk_35;
    wire lcd_rst_n = rst_n_core & pll_lock;

    reg [15:0] H_Pix;
    reg [15:0] V_Pix;
    // 800x480 RGB666 时序（DE 模式 + Pixel-Clock Gated DE，复用 lcd_display.v 已验证值）
    localparam H_VALID = 16'd800;
    localparam H_FP    = 16'd210;
    localparam H_BP    = 16'd182;
    localparam H_TOTAL = H_VALID + H_FP + H_BP;  // 1192
    localparam V_VALID = 16'd480;
    localparam V_FP    = 16'd45;
    localparam V_BP    = 16'd8;
    localparam V_TOTAL = V_VALID + V_FP + V_BP;   // 533

    always @(posedge lcd_pix_clk or negedge lcd_rst_n) begin
        if (!lcd_rst_n) begin
            H_Pix <= 16'd0;
            V_Pix <= 16'd0;
        end else if (H_Pix == H_TOTAL) begin
            H_Pix <= 16'd0;
            if (V_Pix == V_TOTAL)
                V_Pix <= 16'd0;
            else
                V_Pix <= V_Pix + 16'd1;
        end else begin
            H_Pix <= H_Pix + 16'd1;
        end
    end

    wire h_active = (H_Pix >= H_BP) && (H_Pix < H_BP + H_VALID);
    wire v_active = (V_Pix >= V_BP) && (V_Pix < V_BP + V_VALID);
    // 官方 rgb_screen 用 "DE && lcd_clk"（Pixel-Clock Gated DE），照抄以匹配面板
    assign lcd_en = (h_active && v_active) && lcd_pix_clk;

    // ---- LCD 显示：8 段彩条（冒烟验证三通道 / DE / 时序，铺满 800px）----
    localparam CBW = H_VALID / 8;  // 100px
    wire [2:0] bar = (H_Pix - H_BP) / CBW;
    reg [5:0] lcd_r_r, lcd_g_r, lcd_b_r;
    always @(*) begin
        case (bar)
            3'd0: begin lcd_r_r = 6'b111111; lcd_g_r = 6'b000000; lcd_b_r = 6'b000000; end
            3'd1: begin lcd_r_r = 6'b000000; lcd_g_r = 6'b111111; lcd_b_r = 6'b000000; end
            3'd2: begin lcd_r_r = 6'b000000; lcd_g_r = 6'b000000; lcd_b_r = 6'b111111; end
            3'd3: begin lcd_r_r = 6'b111111; lcd_g_r = 6'b111111; lcd_b_r = 6'b000000; end
            3'd4: begin lcd_r_r = 6'b111111; lcd_g_r = 6'b000000; lcd_b_r = 6'b111111; end
            3'd5: begin lcd_r_r = 6'b000000; lcd_g_r = 6'b111111; lcd_b_r = 6'b111111; end
            3'd6: begin lcd_r_r = 6'b111111; lcd_g_r = 6'b111111; lcd_b_r = 6'b111111; end
            default: begin lcd_r_r = 6'b000000; lcd_g_r = 6'b000000; lcd_b_r = 6'b000000; end
        endcase
    end
    assign lcd_r = lcd_r_r;
    assign lcd_g = lcd_g_r;
    assign lcd_b = lcd_b_r;
    assign lcd_clk = lcd_pix_clk;

    // ---------------- WS2812（H16，官方算法，50MHz sys_clk）----------------
    // key3(S3) 按下则关闭（熄灭）；松开恢复彩循环
    // key1(S1)/key2(S2) 按键实时选择亮度档位 lvl（取 key 原样，未按=1）：
    //   按S1+S2=0(0.4%) 按S2=1(100%) 按S1=2(10%) 都不按=3(2% 最暗缺省)
    wire [1:0] ws_lvl = {key2, key1};
    wire ws_off = ~key3;
    ws2812_smoke #(
        .CLK_FRE (50_000_000)
    ) u_ws2812 (
        .clk   (sys_clk),
        .en    (1'b1),
        .off   (ws_off),
        .lvl   (ws_lvl),
        .WS2812(WS2812)
    );

endmodule
