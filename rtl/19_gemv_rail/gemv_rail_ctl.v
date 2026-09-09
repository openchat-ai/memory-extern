`timescale 1ns/1ps
`default_nettype none
//────────────────────────────────────────────────────────────────────────────
// gemv_rail_ctl.v — GEMM 段读控: 把 A-tile 读轨接到 gemv_array_128 (§6)
//
// 思路: 不改 gemv_array_128 的结构 (128 颗 ICG 门控 + 每颗独立 gclk),
// 由本读控把 atile 读轨 (r_valid/r_take/r_data/r_frame_done/r_addr)
// 翻译成 MAC 阵列的食物 (act_in/weight_in 广播)。
//
// A-tile 帧长 = TDEPTH 字, 每字携带 2 枚 16-bit 激活 (低半 a_lo 进 MAC0..,
// 高半留作第二组 lane 的 TODO)。即: 一帧 = 一条 128 维激活向量。
//
// 喂食判据 (关键): claim 沿会造成 r_valid 领先首个 take 一拍 ——
// 若按 r_valid 贪心计数每帧多算 1 拍。改为:
//   feed = r_valid && (首见 || r_addr 变化)
// 每词恰好喂一次; 权重直接取自词序 look_w(r_addr), 与 act 严格配对。
//
// 护栏: lane 每 gclk 都乘累加 (acc<=acc+w*a), 无按拍 valid 门;
// 非喂食沿必须把 act/weight 归零 (0*0 为累加不变量), 否则空拍 x 会
// 乘进累加器。权重流未来由权重 SRAM/LPDDR 预取替换 look_w。
//────────────────────────────────────────────────────────────────────────────
module gemv_rail_ctl #(
    parameter DW     = 32,       // 对接 atile 数据字宽
    parameter TDEPTH = 64,       // 帧字数 (须与 atile TDEPTH 一致)
    parameter AIDX   = 6         // r_addr 位宽 (clog2(TDEPTH), 由调用方给)
)(
    input  wire         clk,
    input  wire         rst_n,

    // atile 读轨
    input  wire         r_valid,
    output reg          r_take,
    input  wire [DW-1:0] r_data,
    input  wire         r_frame_done,
    input  wire [AIDX-1:0] r_addr,

    // MAC 阵列
    output reg  [15:0]  act_in,        // 激活广播 (低半 16bit)
    output reg  [15:0]  weight_in,     // 权重流 (按词序查表)
    output reg          feed           // 喂食沿脉冲 (观测)

    // 统计
    ,output reg [31:0]  words_fed
    ,output reg [31:0]  frames_done
);

    // 权重查表: 词序 -> 权重 (占位: 真实权重由权重 SRAM/LPDDR 预取供给)
    function [15:0] look_w(input integer w);
        begin
            look_w = w;
        end
    endfunction

    reg [AIDX-1:0] prev_r;
    reg           seen;                 // 已见帧内首个 valid

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_take      <= 1'b0;
            prev_r      <= 0;
            seen        <= 1'b0;
            act_in      <= 16'd0;
            weight_in   <= 16'd0;
            feed        <= 1'b0;
            words_fed   <= 0;
            frames_done <= 0;
        end else begin
            // 全速消费: 有 valid 就取 (MAC 无背压, 一把吃穿一帧)
            r_take <= r_valid;

            if (r_valid && (!seen || r_addr != prev_r)) begin
                act_in    <= r_data[15:0];    // 激活低半
                weight_in <= look_w(r_addr);  // 本词权重 (词序=配对键)
                feed      <= 1'b1;
                words_fed <= words_fed + 1'b1;
                prev_r    <= r_addr;
                seen      <= 1'b1;
            end else begin
                act_in    <= 16'd0;           // 归零护栏: 空/重复拍不可污染
                weight_in <= 16'd0;
                feed      <= 1'b0;
            end

            if (r_frame_done) begin
                prev_r      <= 0;
                seen        <= 1'b0;
                frames_done <= frames_done + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire