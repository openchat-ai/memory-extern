// ============================================================================
// board_top_dsplit.v — 数据通路级拆分实验（救 128-lane 布线死循环）
//
// 用途：验证【把 128-lane 归约在数据通路入口拆成两个独立 64-lane 收敛块】
// 能否让 Routing Phase 1 收敛（A 实验已证仅改归约分组 GROP 无用）。
//   engine_core_dsplit：acc_bus 按 lane 切两半，各自 reduction_tree(64,GROUP_LANES=32)，
//   即两个与「已知收敛的 64-lane probe」完全同构的归约块；顶层仅 2 输入部分和相加。
//
// 若本实验 Routing Phase 1 收敛 → 死循环确认为「128 全局 4096bit 归约扇入」，
//   数据通路级拆分是正确解；若仍死 → 连 64 收敛块并行都触发（可能是 simd 阵列
//   128-lane 本身的不随归约拆分的全局网，如 x/wt 广播到 128 lane）。
// ============================================================================
`timescale 1ns/1ps

module board_top_dsplit (
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

    // ---- 完整引擎：数据通路级拆分版 ----
    engine_core_dsplit #(
        .NUM_LANES  (NUM_LANES),
        .ACC_WIDTH  (32),
        .HALF_LANES (64)          // 每独立归约块的 lane 数 = 收敛档位
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