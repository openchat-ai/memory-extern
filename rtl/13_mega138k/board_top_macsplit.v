// ============================================================================
// board_top_macsplit.v — MAC 阵列级拆分实验（救 128-lane 布线死循环）
//
// 用途：验证【把 128-lane 在 MAC 阵列入口就切成两个独立 64-lane 收敛块】
// 能否让 Routing Phase 1 收敛（B 实验 probe_dsplit 已证仅拆归约无用，
// simd_mac_array 128-lane 单实例的全局广播/扇出仍是死循环嫌疑）。
//   engine_core_macsplit：两个独立 simd_mac_array(64) + 各自 reduction_tree(64)，
//   即两个与「已知收敛的 64-lane probe」完全同构的收敛块；顶层仅 2 输入部分和相加。
//
// 若本实验 Routing Phase 1 收敛 → 死循环确认为「128-lane 单 MAC 阵列实例
//   的 x/wt 广播到 128 lane + acc_bus 4096bit 全局扇出」，实例化边界是正确解；
//   若仍死 → 阵列规模本身触发（64×2 并行仍超收敛能力）。
// ============================================================================
`timescale 1ns/1ps

module board_top_macsplit (
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

    reg [26:0] hb_cnt;
    always @(posedge clk_int) begin
        if (!rst_n_core)        hb_cnt <= 27'd0;
        else                    hb_cnt <= hb_cnt + 27'd1;
    end
    assign led[0] = hb_cnt[26];
    assign led[1] = sum_valid | hb_cnt[15];
    assign led[2] = sum_out[0] | hb_cnt[16];
    assign led[3] = (|sum_out[31:1]) ? 1'b0 : hb_cnt[17];

    // ---- 输入由 hb_cnt 驱动，防综合 sweep ----
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

    // ---- 完整引擎：MAC 阵列级拆分版 ----
    engine_core_macsplit #(
        .NUM_LANES  (NUM_LANES),
        .ACC_WIDTH  (32),
        .HALF_LANES (64)          // 每个独立收敛块的 lane 数 = 收敛档位
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

endmodule