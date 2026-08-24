// ============================================================================
// mxfp4_unpacker.v — MXFP4 解包器（保留 Microscaling 语义）
//
// 输入：4 个 E2M1 码 + 共享 E8M0 scale 指数
// 输出：4 个 bf16 操作数（已应用 scale）
//
// MXFP4 = OCP Microscaling FP4 标准
//   实际值 = E2M1码 × 2^(scale - 127)
//   scale 每 group=16 个权重共享一个
// ============================================================================

`timescale 1ns/1ps

module mxfp4_unpacker (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire [15:0] packed_codes,     // 4×E2M1 (每码4bit)
    input  wire [7:0]  scale_exp,       // E8M0 共享指数偏移
    output reg         out_valid,
    output reg  [15:0] w0, w1, w2, w3   // bf16 操作数
);

    // ---- E2M1 → bf16 幅值查表 ----
    function [14:0] e2m1_mag;
        input [2:0] code;
        case (code)
            3'b000: e2m1_mag = 15'h0000; // 0.0  (exp=0,mant=0)
            3'b001: e2m1_mag = 15'h3F00; // 0.5  (exp=126,mant=0) ≈ bf16 0x3F00>>7... 
            3'b010: e2m1_mag = 15'h3F80; // 1.0  
            3'b011: e2m1_mag = 15'h3FC0; // 1.5  
            3'b100: e2m1_mag = 15'h4000; // 2.0  
            3'b101: e2m1_mag = 15'h4040; // 3.0  
            3'b110: e2m1_mag = 15'h4080; // 4.0  
            3'b111: e2m1_mag = 15'h40E0; // 6.0  
        endcase
    endfunction

    // ---- 符号 + 幅值拼接 = 基础 bf16 ----
    function [15:0] e2m1_full;
        input [3:0] code;
        reg [15:0] r;
        begin
            r        = {code[3], e2m1_mag(code[2:0])};
            e2m1_full = r;
        end
    endfunction

    // ---- 应用共享 scale：调整指数域 ----
    // bf16 指数域 [14:7]，直接加上 scale_exp-127 的差值
    function [15:0] apply_scale;
        input [15:0] b16;
        input signed [8:0] sexp;    // scale_exp - 127，有符号
        reg [15:0] r;
        begin
            r = b16;
            r[14:7] = r[14:7] + sexp;
            apply_scale = r;
        end
    endfunction

    // ========================================================================
    // 流水线：解包 → 应用 scale → 输出
    // ========================================================================

    // Stage 0: 锁存输入
    reg [15:0] s0_packed;
    reg [7:0]  s0_scale;
    reg        s0_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s0_valid <= 0;
        else begin
            s0_packed <= packed_codes;
            s0_scale  <= scale_exp;
            s0_valid  <= in_valid;
        end
    end

    // Stage 1: 解包 E2M1 → 基础 bf16（无 scale）
    reg [15:0] s1_v [0:3];
    reg        s1_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) s1_valid <= 0;
        else begin
            s1_v[0] <= e2m1_full(s0_packed[3:0]);
            s1_v[1] <= e2m1_full(s0_packed[7:4]);
            s1_v[2] <= e2m1_full(s0_packed[11:8]);
            s1_v[3] <= e2m1_full(s0_packed[15:12]);
            s1_valid <= s0_valid;
        end
    end

    // Stage 2: 应用共享 scale
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) out_valid <= 0;
        else begin
            out_valid <= s1_valid;
            if (s1_valid) begin
                w0 <= apply_scale(s1_v[0], $signed({1'b0, scale_exp}) - 9'sd127);
                w1 <= apply_scale(s1_v[1], $signed({1'b0, scale_exp}) - 9'sd127);
                w2 <= apply_scale(s1_v[2], $signed({1'b0, scale_exp}) - 9'sd127);
                w3 <= apply_scale(s1_v[3], $signed({1'b0, scale_exp}) - 9'sd127);
            end
        end
    end

endmodule
