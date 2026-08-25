// ============================================================================
// board_top.v — Tang Mega 138K 综合顶层（冒烟测试版）
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
    input  wire sys_clk_p,        // LVDS 正端（V22），Gowin 自动配对负端
    input  wire rst_n_btn,        // 用户按键 AB13
    output wire [3:0] led
);

    // ------------------------------------------------------------------
    // 差分时钟缓冲（Gowin 原语；Verilator lint 用 stub 替代）
    // ------------------------------------------------------------------
    wire clk_int;
    TLVDS_IBUF u_ibuf (.I(sys_clk_p), .O(clk_int));

    // ------------------------------------------------------------------
    // 复位同步 + 按键消抖（简单两级）
    // ------------------------------------------------------------------
    reg [15:0] por_cnt;
    reg        rst_meta;
    reg        rst_sync;
    wire       por_done = (por_cnt == 16'd0);
    wire       rst_n = rst_sync;

    // FPGA 上电初值由 bitstream 提供（Gowin 支持 reg 初值）
    initial begin
        por_cnt  = 16'hFFFF;
        rst_meta = 1'b1;
        rst_sync = 1'b1;
    end

    always @(posedge clk_int) begin
        if (!por_done)
            por_cnt <= por_cnt - 16'd1;
        rst_meta <= rst_n_btn & por_done;
        rst_sync <= rst_meta;
    end

    // ------------------------------------------------------------------
    // LED[0]：心跳（约 1Hz @ 100MHz 输入）
    // ------------------------------------------------------------------
    reg [25:0] hb_cnt;
    always @(posedge clk_int) begin
        if (!rst_n)                 hb_cnt <= 26'd0;
        else                        hb_cnt <= hb_cnt + 26'd1;
    end
    wire heartbeat = hb_cnt[25];

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
        if (!rst_n) begin
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
        .rst_n    (rst_n),
        .wt_valid (pat_en),
        .wt_data  (pat_wt),
        .x_data   (pat_x),
        .x_valid  (pat_en),
        .acc_clr  (~rst_n),
        .sum_out  (sum_out),
        .sum_valid(sum_valid),
        .busy     (engine_busy)
    );
    /* verilator lint_off UNUSEDSIGNAL */
    wire engine_busy;
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------------------------
    // LED[3:1]：引擎活动指示（sum_valid 脉冲计数高位）
    // ------------------------------------------------------------------
    reg [23:0] act_cnt;
    always @(posedge clk_int) begin
        if (!rst_n)              act_cnt <= 24'd0;
        else if (sum_valid)      act_cnt <= act_cnt + 24'd1;
    end

    assign led[0] = heartbeat;
    assign led[1] = sum_valid | act_cnt[22];
    assign led[2] = act_cnt[21];
    assign led[3] = act_cnt[20] ^ (^sum_low);   // XOR 折叠全部 8 位

endmodule
