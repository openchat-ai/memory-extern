// ============================================================================
// board_top_probe.v — 200MHz 布线死循环 [60%] Routing Phase 0 结构二分探针
//
// 用途：build_sweep 已证明卡死与 SDC/DSRM/place/route 无关 → 判为 netlist
// 结构触发布线引擎不收敛。用本探针把"触发因子"二分定位出来：
//
//   1. {PLL + LED 心跳}（无引擎）        → 过 PnR？= 工具/环境健康性基线
//   2. + engine_core NUM_LANES=128      → 卡 [60%]？= 引擎结构触发
//   3. + engine_core NUM_LANES=64/32    → 卡？= lane 规模 vs 结构
//
// 改法：只改本文件里 localparam NUM_LANES（128/64/32），再跑 build_probe.tcl。
// 若方案 1 也卡 → 工具/工程问题，别动 RTL；若只有带引擎才卡 → 把归约/阵列继续二分。
// ----------------------------------------------------------------------------
`timescale 1ns/1ps

module board_top_probe128_g64 (
    input  wire sys_clk,          // P16 板载 50MHz 振荡器
    input  wire rst_n,            // S0（K16）复位按键，低有效
    output wire [3:0] led
);

    // ================= 结构二分开关（A实验：128-lane + 分2组×64） =================
    localparam NUM_LANES   = 128;  // A实验：128-lane 验证死循环是否源于顶层多组归约
    localparam GROUP_LANES = 64;   // 覆盖 engine 默认32 → 128分2组×64，顶层TOP_LANES=2
    localparam PROBE_MODE  = 3;    // 0=无引擎 1=仅MAC阵列 2=仅归约树 3=完整引擎
    // =============================================================

    wire clk_200m;
    wire pll200_lock;
    Gowin_PLL_X200 u_pll200 (
        .clkout0 (clk_200m),
        .lock    (pll200_lock),
        .clkin   (sys_clk)
    );

    wire clk_int = clk_200m;
    wire rst_n_core = rst_n_int & pll200_lock;

    // 复位同步 + 上电延时
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
    // led[3:1] 由引擎输出扇出驱动 → 保证 sum 有扇出，防止引擎被 DCE sweep（NL0002）
    assign led[1] = sum_valid | hb_cnt[15];
    assign led[2] = sum_out[0] | hb_cnt[16];
    assign led[3] = (|sum_out[31:1]) ? 1'b0 : hb_cnt[17];   // 共阳极，灭 = 1

    // ================= 引擎（结构探针：输入由 hb_cnt 驱动，防综合优化） =================
    // 重要：输入恒 0 或 sum 无扇出时，综合会 sweep 整个阵列（实测 REG=45/LUT=10），
    //       探针假通过；必须让 wt/x 非恒定且 sum 有扇出，阵列才真正进入布线器。
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

    // PROBE_MODE 分支：隔离阵列 vs 归约树（保证 sum 有扇出，防 sweep）
    generate
        if (PROBE_MODE == 3) begin : g_engine
            engine_core #(
                .NUM_LANES (NUM_LANES),
                .ACC_WIDTH (32),
                .GROUP_LANES(GROUP_LANES)
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
        end
        else if (PROBE_MODE == 1) begin : g_mac_only
            wire [NUM_LANES*32-1:0] acc_bus_m;
            wire acc_done_w;
            simd_mac_array #(
                .NUM_LANES (NUM_LANES),
                .ACC_WIDTH (32),
                .PIPE_MUL  (1),
                .PIPE_IN   (1)
            ) u_mac_only (
                .clk       (clk_int),
                .rst_n     (rst_n_core),
                .en        (1'b1),
                .wt_valid  (hb_cnt[0]),
                .wt_data   (wt_drv),
                .wt_scale  (8'h40),
                .x_data    (x_drv),
                .x_valid   (hb_cnt[1]),
                .acc_clr   (1'b0),
                .acc_en    (1'b1),
                .acc_out   (acc_bus_m),
                .acc_done  (acc_done_w)
            );
            wire acc_any;
            assign acc_any = |acc_bus_m;
            assign sum_out = {acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_any, acc_bus_m[0], acc_bus_m[1]};
            assign sum_valid = acc_done_w;
        end
        else if (PROBE_MODE == 2) begin : g_tree_only
            wire [NUM_LANES*32-1:0] fake_acc;
            genvar gj;
            for (gj = 0; gj < NUM_LANES*16; gj = gj + 1) begin : fg1
                assign fake_acc[gj] = hb_cnt[gj % 27];
            end
            for (gj = 0; gj < NUM_LANES*16; gj = gj + 1) begin : fg2
                assign fake_acc[NUM_LANES*16 + gj] = ~hb_cnt[(gj + 13) % 27];
            end
            reduction_tree #(
                .NUM_LANES (NUM_LANES),
                .ACC_WIDTH (32)
            ) u_tree_only (
                .clk       (clk_int),
                .rst_n     (rst_n_core),
                .in_valid  (hb_cnt[1]),
                .acc_in    (fake_acc),
                .sum_out   (sum_out),
                .out_valid (sum_valid)
            );
        end
        else begin : g_none
            assign sum_out   = 32'd0;
            assign sum_valid = 1'b0;
        end
    endgenerate

endmodule