// ============================================================================
// board_top_full_macsplit.v — 完整板（128-lane + LCD）集成 MAC 阵列级拆分版
//
// 动机：macsplit（纯引擎，无 LCD）已证 128-lane 拆 2×64 独立 simd_mac_array
//   可布通（unrouted=0, Total 9m53s）。本实验把该结构集成回完整板
//   （128-lane + LCD 35MHz 双时钟域 + 确定性自测激励），验证：
//   (a) 完整板含 LCD/多时钟域是否仍收敛；
//   (b) SDC 时序约束（引擎 200MHz）在拆分结构下是否可达。
//
// 相对 board_top.v 的差异：u_engine 用 engine_core_macsplit（2×64 独立收敛块），
//   其余（LCD、PLL、自测激励、act_cnt、LED）完全一致。
// ============================================================================

`timescale 1ns/1ps

module board_top_full_macsplit (
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
    // 确定性 GEMV 自测激励：固定权重/激活 + 固定拍数，SUM 可预期
    // 真实数据路径（PCIe DMA）接入后删除此段
    // ------------------------------------------------------------------
    localparam NUM_LANES  = 128;
    localparam N_SELFTEST = 16;   // 自测拍数

    // w=E2M1值4 : code=4'b0010(mag=2,sgn=0) → 乘积=4×x
    // x=+1 : 8'b0000_0001
    localparam [3:0] SELFW = 4'b0010;
    localparam [7:0] SELFX = 8'h01;

    reg [NUM_LANES*4-1:0] pat_wt;
    reg [NUM_LANES*8-1:0] pat_x;
    reg                   pat_en;
    reg [4:0]             st_cnt;

    always @(posedge clk_int) begin
        if (!rst_n_core) begin
            pat_wt <= {NUM_LANES*4{1'b0}};
            pat_x  <= {NUM_LANES*8{1'b0}};
            pat_en <= 1'b0;
            st_cnt <= 5'd0;
        end else begin
            // 复位后跑 N_SELFTEST 拍即停，之后保持 SUM 不变
            if (st_cnt < N_SELFTEST) begin
                st_cnt <= st_cnt + 5'd1;
                pat_en <= 1'b1;
                pat_wt <= {NUM_LANES{SELFW}};
                pat_x  <= {NUM_LANES{SELFX}};
            end else
                pat_en <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 引擎核心实例化：MAC 阵列级拆分版（2×64 独立收敛块）
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] sum_out;   // 高位暂未消费，PCIe DMA 阶段回传主机
    /* verilator lint_on UNUSEDSIGNAL */
    wire        sum_valid;
    wire [7:0]  sum_low = sum_out[7:0];

    engine_core_macsplit #(
        .NUM_LANES  (NUM_LANES),
        .ACC_WIDTH  (32),
        .HALF_LANES (64)
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