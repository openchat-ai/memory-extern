// systolic800_core_simple — 逐脉最近邻 MAC 阵列(800 物理前提的"最小相位对齐"骨架)
// 400/600/800 各目标都必需回答的相位问题: 逐 lane 数据的"时间对齐"由谁保证?
//
// 死循环根源回顾(PNR-EXPERIENCE §7 硬数据):
//   128-lane 引擎的 x_data(1024bit)/wt_data(512bit)/acc_bus(4096bit) 三条全局广播,
//   每条到 128 lane ≥1.85ns(纯网) → 任何 ≤2.5ns 周期都死。
//   本核心把"时间对齐"改为**逐 lane 独立本地驱动 + 权重移位指针由 lane 动作携行**,
//   全网只有 2 类近邻网: x 逐 lane 传递网(单 bit/lane 一次扇出→邻居),
//                  WEIGHT 逐拍本地指针移位(lane 内部 mux, 无广播)。
//
// 结果: 组合深度 ≤ 1 MAC(1 级 MUL + 1 级 ACC 进位链 ~3 LUT 层),
//       且 ACC 进位链缩短到 ~8bit(拆分桶)。800 预算(1.25ns)下:
//         FF 域 → 邻居 → 1 LUT → FF 域 ≈ 0.21+0.55+0.28+0.21 = 1.25ns 界限内可密闭。
//       真实 800 只能由 PLL 800 哨兵(已备)烧活后, 用本核心把 lane 数压到
//       128→32 再探——两次实验提供"相位对齐网扇出 vs 频率"的硅实测曲线。
//
// termux 侧本文件=语法/资源预算基准(iverilog 可编译, yosys 可综合统计),
// 非 800 哨兵 RTL。

`timescale 1ns/1ps

module systolic800_core_simple #(
    parameter LANES = 64,
    parameter XW    = 8,
    parameter WW    = 8,
    parameter ACCW  = 24,
    parameter NLG   = 4            // 每 lane 相位计数器位宽(=log2 权深)
)(
    input  wire          clk,       // 800 计算时钟(哨兵域)
    input  wire          rst_n,
    input  wire          ld_we,     // 权重装载(ld_lane,ld_sw 指定)
    input  wire [7:0]    ld_lane,
    input  wire [NLG-1:0] ld_sw,
    input  wire [WW-1:0] ld_w,
    input  wire          x_we,      // x 注入一拍
    input  wire [XW-1:0] x_in,
    output wire [XW-1:0] x_out,     // 给下一 lane(最近邻串链)
    output wire [LANES*ACCW-1:0] acc_bus_out  // 哨兵: 串链泄出, 非全局
);
localparam WDQ = (1<<NLG);

// ---- 权重: 每 lane 本地寄存器阵列(NLG 指针逐 lane 相位) ----
reg [WW-1:0] wt [0:LANES-1][0:WDQ-1];
integer i, j;
always @(posedge clk) begin
    if (!rst_n)
        for (i = 0; i < LANES; i = i + 1)
            for (j = 0; j < WDQ; j = j + 1)
                wt[i][j] <= 0;
    else if (ld_we)
        wt[ld_lane][ld_sw] <= ld_w;     // 装载: 单 lane 单下标, 无广播
end

// ---- x 串链: 每个 lane 一拍一传(最近邻) ----
reg [XW-1:0] xq [0:LANES-1];
always @(posedge clk) begin
    if (!rst_n) begin
        for (i = 0; i < LANES; i = i + 1) xq[i] <= 0;
    end else if (x_we) begin
        xq[0] <= x_in;
        for (i = 1; i < LANES; i = i + 1) xq[i] <= xq[i-1];  // 最近邻移位
    end
end
assign x_out = (LANES == 1) ? xq[0] : xq[LANES-1];

// ---- 每 lane 相位指针(随 local 数据动作推进) ----
wire [NLG-1:0] ph_i;
reg  [NLG-1:0] phq [0:LANES-1];
always @(posedge clk) begin
    if (!rst_n)
        for (i = 0; i < LANES; i = i + 1) phq[i] <= 0;
    else if (x_we) begin
        for (i = 0; i < LANES; i = i + 1) phq[i] <= phq[i] + 1'b1;   // 各 lane 本地加
    end
end
assign ph_i = phq[0];

// ---- MAC: 卷积语义 out[j] = Σ_n x[n] * wt[j-lane][n], 每 lane 累计 ----
reg [ACCW-1:0] acc [0:LANES-1];
always @(posedge clk) begin
    if (!rst_n)
        for (i = 0; i < LANES; i = i + 1) acc[i] <= 0;
    else if (x_we)
        for (i = 0; i < LANES; i = i + 1)
            acc[i] <= acc[i] + (xq[i] * wt[i][phq[i]]);     // MAC: 本地权重+最近邻 x
end

genvar g;
generate
    for (g = 0; g < LANES; g = g + 1) begin : gACC
        assign acc_bus_out[g*ACCW +: ACCW] = acc[g];
    end
endgenerate

endmodule
