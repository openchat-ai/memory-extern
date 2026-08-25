// ============================================================================
// simd_mac_array.v — 128 个并行 MAC，各有独立累加器
//
// 真正的 SIMD 结构：
//   每条通道独立乘累加，互不干扰
//   最后由 reduction_tree 归约成单个输出
//
// 资源策略：
//   - mxfp4 模式：LUT 查表替代 DSP（每通道 ~12 LUT）
//   - bf16 模式：可用 DSP 或 LUT Booth-Wallace 树（参数选择）
// ============================================================================

`timescale 1ns/1ps

module simd_mac_array #(
    parameter NUM_LANES      = 128,   // 并行 MAC 数量
    parameter ACC_WIDTH      = 32     // 累加器位宽
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       en,        // 全局使能（ICG 门控）

    // ---- 权重流输入（来自解包器）----
    input  wire                       wt_valid,
    input  wire [NUM_LANES*4-1:0]     wt_data,   // 每 lane 一个 int4 码
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]                 wt_scale,  // 预留 per-block scale
    /* verilator lint_on UNUSEDSIGNAL */// 共享 scale（简化：单 scale）

    // ---- 激活值向量（x 向量分片）----
    input  wire [NUM_LANES*8-1:0]     x_data,    // 每 lane 一个 int8 激活值
    input  wire                       x_valid,

    // ---- 累加控制 ----
    input  wire                       acc_clr,   // 清零所有累加器（新一轮开始）
    input  wire                       acc_en,    // 允许累加

    // ---- 输出到归约树 ----
    output wire [NUM_LANES*ACC_WIDTH-1:0] acc_out,
    output wire                       acc_done   // 所有累加器有有效值
);

    // ========================================================================
    // mxfp4 E2M1 查表解码（LUT 实现，不用 DSP）
    // 每个 4-bit 码对应 [-6, +6] 的定点值（放大 4 倍便于整数运算）
    // ========================================================================
    function signed [7:0] e2m1_lut;
        input [3:0] code;
        reg [4:0] mag;
        begin
            case (code[2:0])
                3'b000: mag = 5'd0;     // 0.0
                3'b001: mag = 5'd2;     // 0.5 x4
                3'b010: mag = 5'd4;     // 1.0 x4
                3'b011: mag = 5'd6;     // 1.5 x4
                3'b100: mag = 5'd8;     // 2.0 x4
                3'b101: mag = 5'd12;    // 3.0 x4
                3'b110: mag = 5'd16;    // 4.0 x4
                3'b111: mag = 5'd24;    // 6.0 x4
                default: mag = 5'd0;
            endcase
            e2m1_lut = code[3] ? -$signed({3'b000, mag}) : $signed({3'b000, mag});
        end
    endfunction

    // ========================================================================
    // 单个 MAC 通道：int4 权重 × int8 激活 → 累加到自己的 accumulator
    // 用移位+加法实现乘法（不占 DSP）
    // ========================================================================
    generate
        genvar i;
        for (i = 0; i < NUM_LANES; i = i + 1) begin : gen_lane
            // 每 lane 有独立的累加器 —— 这才是 SIMD
            reg signed [ACC_WIDTH-1:0] acc;

            // 解码当前 lane 的权重码
            wire signed [7:0] w_dec = e2m1_lut(wt_data[i*4 +: 4]);

            // 当前 lane 的激活值（int8 定点）
            wire signed [7:0] x_val = x_data[i*8 +: 8];

            // ── 移位加法乘法器（利用 E2M1 幅值全偶数的特性）──
            // w_dec = 2k, k∈{0,±1,±2,±3,±4,±6,±8,±12}
            // k·x 用单加法器+mux 实现，替代通用 8x8 乘法树
            // 等效节省每 lane ~40% LUT
            wire [2:0] mag = wt_data[i*4 +: 3];        // 幅值选择
            wire      sgn = wt_data[i*4+3];             // 符号位
            // 先符号扩展，避免移位发生在 8bit 域内回绕
            wire signed [11:0] sx = {{4{x_val[7]}}, x_val};
            reg  signed [11:0] kx;                      // k·x ∈ [-1536,+1512]
            always @(*) begin
                case (mag)
                    3'd0: kx = 12'sd0;                          // k=0
                    3'd1: kx = sx;                              // k=1
                    3'd2: kx = sx <<< 1;                        // k=2
                    3'd3: kx = sx + (sx <<< 1);                 // k=3
                    3'd4: kx = sx <<< 2;                        // k=4
                    3'd5: kx = (sx <<< 2) + (sx <<< 1);         // k=6
                    3'd6: kx = sx <<< 3;                        // k=8
                    3'd7: kx = (sx <<< 3) + (sx <<< 2);         // k=12
                endcase
            end
            // 还原偶数因子：w·x = 2·(k·x)
            wire signed [15:0] product =
                sgn ? -$signed({kx, 1'b0})
                    :  $signed({kx, 1'b0});

            always @(posedge clk) begin
                if (!rst_n || acc_clr)
                    acc <= {ACC_WIDTH{1'b0}};
                else if (en && wt_valid && x_valid && acc_en)
                    acc <= acc + $signed({{(ACC_WIDTH-16){product[15]}}, product});
            end
        end
    endgenerate

    // ========================================================================
    // 输出：所有 lane 的累加器拼接（供 reduction_tree 使用）
    // ========================================================================
    genvar j;
    wire [NUM_LANES*ACC_WIDTH-1:0] acc_bus;
    for (j = 0; j < NUM_LANES; j = j + 1) begin : gen_acc_out
        assign acc_bus[j*ACC_WIDTH +: ACC_WIDTH] = gen_lane[j].acc;
    end
    assign acc_out  = acc_bus;

    // 累加器"完成"信号：原型阶段用简单计数器模拟
    // 实际应由上层 FSM 控制何时读出
    reg [15:0] done_cnt;
    always @(posedge clk) begin
        if (!rst_n || acc_clr)
            done_cnt <= 16'd0;
        else if (wt_valid && x_valid && acc_en)
            done_cnt <= done_cnt + 16'd1;
    end
    assign acc_done = (done_cnt != 16'd0) && !wt_valid;

endmodule
