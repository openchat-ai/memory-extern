// board_lcd_test.v — 独立 LCD 小位流 (2026-10-22)
// 目的: 让"显示相关"的改动 (字库/字符串/字段/布局) 只需 1~2 分钟一轮,
//       而不是整包 PnR 的 16 分钟。原理: 同一个 lcd_display 驱动 + 同样的
//       6 行标签, 但只带 PLL + 计数器/LFSR, 规模 ~几千 LUT (整包 25K)。
// 板级用法: 烧这个位流 → 看屏上 6 行是否正确 → 改完并回整包 (build_decode_top.tcl)。
// 注意: 烧它会覆盖板上的 decode 位流, 看��要重烧整包。
module board_lcd_test (
    input  wire sys_clk,
    input  wire rst_n,
    output wire [5:0] led,
    // ---- LCD 800x480 RGB666 ----
    output wire       lcd_clk,
    output wire       lcd_en,
    output wire       lcd_hs,
    output wire       lcd_vs,
    output wire [5:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [5:0] lcd_b
);
    wire        lcd_clk_35;
    wire        pll_lock;

    // ---- 1Hz 拍 (50e6 拍 = 1 秒) ----
    reg [25:0] sec_cnt = 0;
    reg        sec_tick = 0;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            sec_cnt <= 26'd0; sec_tick <= 1'b0;
        end else begin
            if (sec_cnt == 26'd49999999) begin
                sec_cnt <= 26'd0; sec_tick <= 1'b1;
            end else begin
                sec_cnt <= sec_cnt + 26'd1; sec_tick <= 1'b0;
            end
        end

    // ---- 慢变量: 每秒变一次的帧计数 / 帧哈希 / 判活位图 ----
    reg [31:0] lfsr = 32'hC0FF_EE13;
    reg [23:0] snap_frm = 0;
    reg [31:0] snap_hash = 0;
    reg [23:0] snap_pass = 7;
    always @(posedge sys_clk or negedge rst_n)
        if (!rst_n) begin
            lfsr <= 32'hC0FF_EE13; snap_frm <= 24'd0; snap_hash <= 32'd0; snap_pass <= 24'd7;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            if (sec_tick) begin
                snap_frm  <= snap_frm + 24'd24414;      // 假装板级帧率
                snap_hash <= lfsr;
                snap_pass <= 24'd7;
            end
        end

    assign led[0] = ~sec_tick;      // 1Hz 心跳
    assign led[1] = ~pll_lock;      // PLL 锁定
    assign led[2] = 1'b1;
    assign led[3] = 1'b1;
    assign led[4] = 1'b1;
    assign led[5] = 1'b1;

    Gowin_PLL u_pll (
        .clkout0 (lcd_clk_35),
        .lock    (pll_lock),
        .clkin   (sys_clk)
    );

    lcd_display #(
        .TITLE   ("DECODE STATUS"),
        .LBL1    ("FPS:   "),
        .LBL2    ("XEXT:  "),
        .LBL3    ("HASH:  "),
        .LBL4    ("FRM:   "),
        .LBL5    ("PASS:  "),
        .L1_WORD (1'b0),
        .NLINES  (6)
    ) u_lcd (
        .lcd_clk     (lcd_clk_35),
        .rst_n       (pll_lock),
        .act_cnt     (snap_frm[23:0]),
        .cnt1        (24'd6),          // XEXT
        .cnt2        (24'd24414),       // FPS
        .val8        (snap_hash),
        .cnt4        (snap_frm),
        .cnt5        (snap_pass),
        .lcd_clk_o   (lcd_clk),
        .lcd_en      (lcd_en),
        .lcd_hs      (lcd_hs),
        .lcd_vs      (lcd_vs),
        .lcd_r       (lcd_r),
        .lcd_g       (lcd_g),
        .lcd_b       (lcd_b)
    );
endmodule
