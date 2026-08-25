// ============================================================================
// activation_vec.v — 向量化激活函数（GELU/SiLU 近似）
//
// 用 DSP 做多项式拟合（复用空闲 DSP，替代 LUT 查表省 BRAM）
// 输入：int32 累加值 → 输出：int8 激活值（供下一层使用）
//
// 多项式近似：
//   GELU(x) ≈ 0.5x(1 + tanh(√(2/π)(x + 0.044715x³)))
//   用 3 阶多项式近似 tanh 段
// ============================================================================

`timescale 1ns/1ps

module activation_vec #(
    parameter NUM_LANES = 128,
    parameter IN_WIDTH  = 32,
    parameter OUT_WIDTH = 8
)(
    input  wire                        clk,
    input  wire                        rst_n,
    input  wire                        en,

    input  wire                        in_valid,
    input  wire [NUM_LANES*IN_WIDTH-1:0] x_in,
    output reg                         out_valid,
    output reg  [NUM_LANES*OUT_WIDTH-1:0] y_out
);

    // ========================================================================
    // 单通道 GELU 近似（分段线性 + 3 阶修正项）
    // 用 2 级流水：第 1 拍算 x² 和符号判断；第 2 拍算最终值
    // ========================================================================
    task auto_gelu;
        input signed [IN_WIDTH-1:0] x;
        output signed [OUT_WIDTH-1:0] y;
        reg signed [IN_WIDTH-1:0] x_abs;
        reg signed [OUT_WIDTH-1:0] corr;  /* verilator lint_off UNUSEDSIGNAL */
        reg signed [OUT_WIDTH-1:0] y_pos;
        begin
            x_abs = (x < 0) ? -$signed(x) : x;

            if (x_abs < 8)
                y_pos = x[OUT_WIDTH-1:0];
            else if (x_abs < 64) begin
                begin : corr_blk
                    reg [31:0] full;
                    full = (x_abs * x_abs * x_abs) >>> 13;
                    corr = x_abs[OUT_WIDTH-1:0] - full[OUT_WIDTH-1:0];
                end
                y_pos = corr[OUT_WIDTH-1:0];
            end else
                y_pos = {OUT_WIDTH{1'b0}} | 8'h7F;

            y = (x < 0) ? (-y_pos) : y_pos;
        end
    endtask

    // ========================================================================
    // 流水线处理所有 lane
    // ========================================================================
    genvar i;
    generate
        for (i = 0; i < NUM_LANES; i = i + 1) begin : gen_act
            reg signed [IN_WIDTH-1:0]  x_pipe;
            reg signed [OUT_WIDTH-1:0] y_pipe;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    x_pipe <= {IN_WIDTH{1'b0}};
                    y_pipe <= {OUT_WIDTH{1'b0}};
                end else if (en) begin
                    // Stage 1: 锁存输入
                    x_pipe <= $signed(x_in[i*IN_WIDTH +: IN_WIDTH]);

                    // Stage 2: 计算激活
                    auto_gelu(x_pipe, y_pipe);
                end
            end

            assign y_out[i*OUT_WIDTH +: OUT_WIDTH] = y_pipe;
        end
    endgenerate

    // 输出有效信号（延迟 2 拍）
    reg [1:0] v_shift;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            v_shift <= 2'b00;
        else
            v_shift <= {v_shift[0], in_valid};
    end
    always @(posedge clk) out_valid <= v_shift[1];

endmodule
