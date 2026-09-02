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

module board_top_probe (
    input  wire sys_clk,          // P16 板载 50MHz 振荡器
    input  wire rst_n,            // S0（K16）复位按键，低有效
    output wire [3:0] led
);

    // ================= 结构二分开关（只改这里） =================
    localparam NUM_LANES = 128;   // 128 / 64 / 32 二分；0 支持仍需留引擎结构被封死
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
    assign led[3:1] = 3'b000;   // 共阳极，灭 = 1

    // ================= 引擎（恒静态输入，探结构不跑数据） =================
    wire [31:0] sum_out;
    wire        sum_valid;
    wire        busy;

    engine_core #(
        .NUM_LANES (NUM_LANES),
        .ACC_WIDTH (32)
    ) u_engine (
        .clk        (clk_int),
        .rst_n      (rst_n_core),
        .wt_valid   (1'b0),
        .wt_data    ({NUM_LANES*4{1'b0}}),
        .x_data     ({NUM_LANES*8{1'b0}}),
        .x_valid    (1'b0),
        .acc_clr    (1'b0),
        .sum_out    (sum_out),
        .sum_valid  (sum_valid),
        .busy       (busy)
    );

endmodule