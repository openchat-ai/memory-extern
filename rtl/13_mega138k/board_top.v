// ============================================================================
// board_top.v — Tang Mega 138K Pro 综合顶层（冒烟测试版）
//
// 目标：
//   1. 验证时钟/复位/LED 引脚约束正确
//   2. 引擎核心在真实 fabric 上编译通过
//   3. LED 心跳 + 活动指示，上电即可观察
//
// 后续步骤：接入 PCIe DMA 权重流，替换本文件的自由测试激励
// ============================================================================

`timescale 1ns/1ps

module board_top (
    input  wire sys_clk,          // P16 板载 50MHz 振荡器，单端
    input  wire rst_n,            // 复位按键 S0（K16）
    output wire [3:0] led,
    // ---- LCD（800x480 RGB666 Dock 屏）----
    output wire        lcd_clk,
    output wire        lcd_en,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire [5:0]  lcd_r,
    output wire [5:0]  lcd_g,
    output wire [5:0]  lcd_b
);

    // ------------------------------------------------------------------
    // 引擎时钟：PLL 把板上 50MHz 倍频到 200MHz（VCO=800, ODIV0=4）
    // 打断关键路径（PIPE_MUL=1）后，每段组合逻辑可在 5ns 内收敛
    // ------------------------------------------------------------------
    wire        clk_200m;
    wire        pll200_lock;
    Gowin_PLL_X200 u_pll200 (
        .clkout0 (clk_200m),
        .lock    (pll200_lock),
        .clkin   (sys_clk)
    );

    wire clk_int = clk_200m;
    wire rst_n_core = rst_n_int & pll200_lock;

    // ------------------------------------------------------------------
    // 复位同步 + 上电延时（按键低有效）
    // ------------------------------------------------------------------
    reg [15:0] por_cnt;
    reg        rst_meta;
    reg        rst_sync;
    wire       por_done = (por_cnt == 16'd0);
    wire       rst_n_int = rst_sync;

    // FPGA 上电初值由 bitstream 提供（Gowin 支持 reg 初值）
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

    // ------------------------------------------------------------------
    // LED[0]：心跳（约 1Hz @ 200MHz 输入 → 27-bit 计数）
    // ------------------------------------------------------------------
    reg [26:0] hb_cnt;
    always @(posedge clk_int) begin
        if (!rst_n_core)        hb_cnt <= 27'd0;
        else                    hb_cnt <= hb_cnt + 27'd1;
    end
    wire heartbeat = hb_cnt[26];

    // ------------------------------------------------------------------
    // 自由运行激励：权重码递增、激活固定模式，验证 MAC 阵列翻转
    // 真实数据路径（PCIe DMA）接入后删除此段
    // ------------------------------------------------------------------
    localparam NUM_LANES = 128;

    /* verilator lint_off UNUSEDSIGNAL */
    reg [NUM_LANES*4-1:0] pat_wt;
    reg [NUM_LANES*8-1:0] pat_x;
    /* verilator lint_on UNUSEDSIGNAL */
    reg                   pat_en;
    reg [9:0]             burst_cnt;

    integer i;
    // 突发模式：跑 16 拍停 1000 拍，循环往复
    always @(posedge clk_int) begin
        if (!rst_n_core) begin
            pat_wt    <= {NUM_LANES*4{1'b0}};
            pat_x     <= {NUM_LANES*8{1'b0}};
            pat_en    <= 1'b0;
            burst_cnt <= 10'd0;
        end else begin
            burst_cnt <= burst_cnt + 10'd1;
            if (burst_cnt < 10'd16)
                pat_en <= 1'b1;
            else
                pat_en <= 1'b0;

            if (pat_en) begin
                /* verilator lint_off UNUSEDLOOP */
                for (i = 0; i < NUM_LANES; i = i + 1) begin
                /* verilator lint_on UNUSEDLOOP */
                    pat_wt[i*4 +: 4] <= pat_wt[i*4 +: 4] + 4'd1;
                    pat_x [i*8 +: 8] <= pat_x [i*8 +: 8] + 8'd3;
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // 引擎核心实例化
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] sum_out;   // 高位暂未消费，PCIe DMA 阶段回传主机
    /* verilator lint_on UNUSEDSIGNAL */
    wire        sum_valid;
    wire [7:0]  sum_low = sum_out[7:0];

    engine_core #(
        .NUM_LANES(NUM_LANES),
        .ACC_WIDTH(32)
    ) u_engine (
        .clk      (clk_int),
        .rst_n    (rst_n_core),
        .wt_valid (pat_en),
        .wt_data  (pat_wt),
        .x_data   (pat_x),
        .x_valid  (pat_en),
        .acc_clr  (~rst_n_core),
        .sum_out  (sum_out),
        .sum_valid(sum_valid),
        .busy     (engine_busy)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire engine_busy;
    /* verilator lint_on UNUSEDSIGNAL */

    // 引擎活动计数（LED + LCD 共用）
    reg [23:0] act_cnt;
    always @(posedge clk_int) begin
        if (!rst_n_core)             act_cnt <= 24'd0;
        else if (sum_valid)      act_cnt <= act_cnt + 24'd1;
    end

    // ------------------------------------------------------------------
    // LCD 显示：PLL 50M→35M 像素时钟，engine 状态实时上屏
    // ------------------------------------------------------------------
    wire        lcd_clk_35;
    wire        pll_lock;

    Gowin_PLL u_pll (
        .clkout0 (lcd_clk_35),
        .lock    (pll_lock),
        .clkin   (sys_clk)
    );

    lcd_display u_lcd (
        .lcd_clk     (lcd_clk_35),
        .rst_n       (pll_lock),
        .act_cnt     (act_cnt),
        .sum_out     (sum_out),
        .engine_busy (engine_busy),
        .lcd_clk_o   (lcd_clk),
        .lcd_en      (lcd_en),
        .lcd_hs      (lcd_hs),
        .lcd_vs      (lcd_vs),
        .lcd_r       (lcd_r),
        .lcd_g       (lcd_g),
        .lcd_b       (lcd_b)
    );

    // ------------------------------------------------------------------
    // LED[3:1]：引擎活动指示（sum_valid 脉冲计数高位）
    // ------------------------------------------------------------------

    // LED 共阳极：IO 拉低点亮，故取反驱动
    assign led[0] = ~heartbeat;
    assign led[1] = ~(sum_valid | act_cnt[22]);
    assign led[2] = ~act_cnt[21];
    assign led[3] = ~(act_cnt[20] ^ (^sum_low));   // XOR 折叠全部 8 位

endmodule
