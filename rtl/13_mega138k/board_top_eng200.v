// ============================================================================
// board_top_eng200.v — 二分实验：128-lane + 200MHz 单时钟域（无 LCD、无多时钟域）
//
// 目的：区分"128-lane 引擎规模" vs "LCD + 多时钟域跨域路径" 谁是
//       Routing Phase 1 不收敛的主因。
//   - 若此版本布通（≈0 unrouted）→ 主因锁定 LCD/多时钟域，回填完整 board_top
//   - 若仍 >1000 unrouted   → 主因锁定 128-lane 规模，走 route_option/place_option 梯度
//
// 与 board_top.v 的差异：无 LCD、无 sys_clk 交叉、单 200MHz PLL 时钟域，
// 引擎接真实时钟 clk_200m；LED 心跳 + 引擎活动指示（防引擎被 DCE sweep）。
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

module board_top_eng200 (
    input  wire sys_clk,          // P16 板载 50MHz 振荡器
    input  wire rst_n,            // S0（K16）复位按键，低有效
    output wire [3:0] led
);

    localparam NUM_LANES = 128;

    wire clk_200m;
    wire pll200_lock;
    Gowin_PLL_X200 u_pll200 (
        .clkout0 (clk_200m),
        .lock    (pll200_lock),
        .clkin   (sys_clk)
    );

    wire clk_int = clk_200m;
    wire rst_n_core = rst_n_int & pll200_lock;

    reg [15:0] por_cnt;
    reg        rst_meta;
    reg        rst_sync;
    wire       por_done = (por_cnt == 16'd0);
    wire       rst_n_int = rst_sync;

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

    // LED[0]：心跳（~1Hz @ 200MHz → 27-bit 计数）
    reg [26:0] hb_cnt;
    always @(posedge clk_int) begin
        if (!rst_n_core)        hb_cnt <= 27'd0;
        else                    hb_cnt <= hb_cnt + 27'd1;
    end
    assign led[0] = hb_cnt[26];
    assign led[1] = sum_valid | hb_cnt[15];
    assign led[2] = sum_out[0] | hb_cnt[16];
    assign led[3] = (|sum_out[31:1]) ? 1'b0 : hb_cnt[17];

    // 引擎输入由 hb_cnt 驱动，防综合优化 sweep 掉阵列（NL0002）
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

    engine_core #(
        .NUM_LANES (NUM_LANES),
        .ACC_WIDTH (32)
    ) u_engine (
        .clk        (clk_int),
        .rst_n      (rst_n_core),
        .wt_valid   (hb_cnt[0]),
        .wt_data    (wt_drv),
        .x_data     (x_drv),
        .x_valid    (hb_cnt[1]),
        .acc_clr    (1'b0),
        .sum_out    (sum_out),
        .sum_valid  (sum_valid),
        .busy       (busy)
    );

endmodule