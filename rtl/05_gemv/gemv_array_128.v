`timescale 1ns/1ps
// ============================================================================
// gemv_array_128.v — GEMV 芯片 MAC 阵列骨架（128 预埋派 + 每 MAC 独立门控）
//
// 定案依据：notes/architecture-decision.md §5.5（v0.4，2026-08-23）
//   8ch LPDDR5X(171GB/s) 下 ~86 颗活跃即可喂饱；其余 ICG 门控仅漏电。
//   未来 16ch/LPDDR6 升级时解除门控直接解锁全部 128 颗——免重流。
//
// 状态：集成骨架。mac_lane 本体待接 periph_mac_bf16 / dequant 流水（TODO 标注）。
// ============================================================================

// ----------------------------------------------------------------------------
// ICG 等效行为模型：latch-based clock gate
// 流片时替换为代工厂 ICG cell（如 SMIC 14nm 的 cklatn 类单元），
// 接口保持 clk/en/gclk 不变即可。
// ----------------------------------------------------------------------------
module cg_gate (
    input  wire clk,
    input  wire en,          // 高有效：允许时钟通过
    output wire gclk
);
    reg latched;
    // 负沿锁存 enable → 消除毛刺的标准 ICG 结构
    always @(clk or en) begin
        if (!clk) latched <= en;
    end
    assign gclk = clk & latched;
endmodule

// ----------------------------------------------------------------------------
// MAC lane 集成占位：标明与 periph_mac_bf16 的对接点
// 实际数据通路（dequant → bf16 MAC → 累加）在独立栈 RTL 中补全，
// 本骨架先确立【数量 128 + 每颗独立门控】的阵列结构。
// ----------------------------------------------------------------------------
module mac_lane_placeholder (
    input  wire        gclk,        // 门控后的本地时钟——闲置时此钟停振
    input  wire        rst,
    input  wire        lane_active, // 与 gclk 同源的使能（供逻辑使用）
    input  wire [15:0] wdata,       // 权重流（bf16 或 mxfp4 解包后）
    input  wire [15:0] adata,       // 激活广播
    output reg  [15:0] acc
);
    always @(posedge gclk or negedge rst) begin
        if (!rst) acc <= 16'b0;
        else      acc <= acc + ($signed(wdata) * $signed(adata)); // 占位乘累加
    end
endmodule

// ----------------------------------------------------------------------------
// 128 颗 MAC 阵列顶层
// ----------------------------------------------------------------------------
module gemv_array_128 #(
    parameter MAC_COUNT = 128       // 预埋派定标（ADR v0.4）
) (
    input  wire         clk,        // 全局源时钟
    input  wire         rst_n,
    // 每 MAC 独立使能（固件经 CSR/熔丝配置；上电默认仅前 86 颗开）
    input  wire [MAC_COUNT-1:0] mac_en,
    // 权重/激活流（来自 LPDDR 控制器与广播网络）
    input  wire [15:0]  weight_in,
    input  wire [15:0]  act_in,
    // 输出累加总线（汇总到片上累加网络）
    output wire [15:0]  acc_out,
    // 观测
    output wire [$clog2(MAC_COUNT)-1:0] active_cnt
);
    genvar i;
    wire [MAC_COUNT-1:0] gclk;
    wire [15:0] lane_acc [0:MAC_COUNT-1];

    generate
        for (i = 0; i < MAC_COUNT; i = i + 1) begin : LANE
            cg_gate u_cg (
                .clk (clk),
                .en  (mac_en[i]),
                .gclk(gclk[i])
            );
            mac_lane_placeholder u_lane (
                .gclk       (gclk[i]),
                .rst        (rst_n),
                .lane_active(mac_en[i]),
                .wdata      (weight_in),     // TODO: 按 lane 分片的权重流
                .adata      (act_in),        // TODO: 广播网络对接
                .acc        (lane_acc[i])
            );
        end
    endgenerate

    // 活跃计数（供固件轮询功耗状态）
    reg [$clog2(MAC_COUNT+1)-1:0] act_q;
    integer j;
    always @(*) begin
        act_q = 0;
        for (j = 0; j < MAC_COUNT; j = j + 1)
            if (mac_en[j]) act_q = act_q + 1'b1;
    end
    assign active_cnt = act_q;

    // 累加汇总（占位：实际为加法器树/NOC 汇聚，TODO）
    assign acc_out = lane_acc[0];   // TODO: 树形归约

endmodule
