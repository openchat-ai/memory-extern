`timescale 1ns/1ps
// 05_gemv — 内存侧数字外围：bf16 加法器（IEEE-754 RN，逐位同 C）
//
// 版本 B（流片目标）的核心：MX 生态标准的累加精度（bf16：1+8+7）。
// 北极星权重层真实语义 = MXFP4 尾数 × E8M0 尺度，跨组累加用 bf16/fp32；
// bf16 加法器把 f32_add 的尾数从 24 位降到 8 位，面积缩小 3-4 倍
// → 整个演示可压进 1 tile（≤1000 cells）。
//
// 结构与 f32_add.v 完全同构（教科书式一次舍入），仅位宽不同：
//   解码 → 对齐（10 位尾数，含 2 guard 位 + sticky）→ 加/减 → 规格化
//   → RN-even 舍入 → 组装（正规/次正规/±inf/±0/NaN）。
// 指数域同 fp32（8 位，偏置 127），溢出/次正规边界与 f32 相同，
// 区别只在尾数 7 位 → 有效数 8 位 → 10 位运算路径。
//
// 值 = m10 × 2^(e-9)，m10 = {1.mantissa, 2'b00}（8+2 位，首 1 在 bit9）。
module bf16_add (
    input  wire [15:0] a,
    input  wire [15:0] b,
    output reg  [15:0] y
);
    wire       a_s = a[15], b_s = b[15];
    wire [7:0] a_e = a[14:7], b_e = b[14:7];
    wire [6:0] a_m = a[6:0], b_m = b[6:0];

    wire a_nan = (a_e == 8'hFF) && (a_m != 0);
    wire b_nan = (b_e == 8'hFF) && (b_m != 0);
    wire a_inf = (a_e == 8'hFF) && (a_m == 0);
    wire b_inf = (b_e == 8'hFF) && (b_m == 0);
    wire a_zero = (a_e == 0) && (a_m == 0);
    wire b_zero = (b_e == 0) && (b_m == 0);

    wire signed [8:0] a_eu = a_zero ? -9'sd127
                          : (a_e == 0) ? -9'sd126
                          : $signed({1'b0, a_e}) - 9'sd127;
    wire signed [8:0] b_eu = b_zero ? -9'sd127
                          : (b_e == 0) ? -9'sd126
                          : $signed({1'b0, b_e}) - 9'sd127;
    // 10 位尾数（8 有效位 + 2 guard）。值 = m10 × 2^(e-9)。
    wire [9:0] a_m10 = a_zero ? 10'd0 : {(a_e != 0), a_m, 2'b00};
    wire [9:0] b_m10 = b_zero ? 10'd0 : {(b_e != 0), b_m, 2'b00};

    wire same_sign = (a_s == b_s);
    wire hi_a = (a_eu > b_eu);

    wire signed [8:0] eh = hi_a ? a_eu : b_eu;
    wire [9:0] mh = hi_a ? a_m10 : b_m10;
    wire [9:0] ml = hi_a ? b_m10 : a_m10;
    wire [8:0] dif = hi_a ? (a_eu - b_eu) : (b_eu - a_eu);

    wire [8:0] difc = (dif > 9'd10) ? 9'd10 : dif;
    wire [9:0] ml_sh = (ml >> difc);
    wire [9:0] lowmask = (difc == 9'd0) ? 10'd0
                       : (difc == 9'd10) ? 10'h3FF
                       : (10'h1 << difc) - 10'd1;
    wire stk = (difc != 0) && (|(ml & lowmask));

    reg [10:0] msum;
    reg        cneg;
    always @(*) begin
        if (same_sign) begin
            msum = {1'b0, mh} + {1'b0, ml_sh};
            cneg = a_s;
        end else if (mh >= ml_sh) begin
            msum = {1'b0, mh} - {1'b0, ml_sh} - (stk ? 11'd1 : 11'd0);
            cneg = hi_a ? a_s : b_s;
        end else begin
            msum = {1'b0, ml_sh} - {1'b0, mh};
            cneg = hi_a ? b_s : a_s;
        end
    end

    wire [10:0] ms1 = msum[10] ? (msum >> 1) : msum;
    wire signed [8:0] E0 = eh + (msum[10] ? 9'sd1 : 9'sd0);

    reg [3:0] nz;
    always @(*) begin
        nz = 4'd11;
        if      (ms1[9])  nz = 4'd0;
        else if (ms1[8])  nz = 4'd1;
        else if (ms1[7])  nz = 4'd2;
        else if (ms1[6])  nz = 4'd3;
        else if (ms1[5])  nz = 4'd4;
        else if (ms1[4])  nz = 4'd5;
        else if (ms1[3])  nz = 4'd6;
        else if (ms1[2])  nz = 4'd7;
        else if (ms1[1])  nz = 4'd8;
        else if (ms1[0])  nz = 4'd9;
    end
    wire [10:0] mnorm = ms1 << nz;

    wire signed [8:0] E = E0 - $signed({1'b0, nz});

    wire result_zero = (msum == 11'd0);

    wire g = mnorm[1];
    wire r = mnorm[0];
    wire s = stk | (msum[10] ? msum[0] : 1'b0);
    wire lsb = mnorm[2];
    wire round_up = g & (r | s | lsb);
    wire [8:0] frac_plus = {1'b0, mnorm[9:2]} + (round_up ? 9'd1 : 9'd0);
    wire carry = frac_plus[8];
    wire signed [8:0] E_r = E + (carry ? 9'sd1 : 9'sd0);
    wire [6:0] frac_r = carry ? 7'd0 : frac_plus[6:0];

    wire is_inf = !result_zero && (E_r > 9'sd127);
    wire is_sub = !result_zero && !is_inf && (E < -9'sd126);

    wire signed [8:0] R = -E - 9'sd124;
    wire [8:0] Rc = (R > 9'd150) ? 9'd150 : R;
    wire [10:0] msub_sh = (mnorm >> Rc);
    wire [8:0] Rm1 = (Rc == 9'd0) ? 9'd0 : (Rc - 9'd1);
    wire [9:0] sub_lowmask = (Rc == 9'd0) ? 10'd0
                           : (Rc >= 9'd10) ? 10'h3FF
                           : (10'h1 << Rm1) - 10'd1;
    wire sub_g = (Rc == 9'd0) ? 1'b0 : mnorm[Rc - 9'd1];
    wire sub_stk = stk | ((Rc > 9'd0) && (|(mnorm & sub_lowmask)));
    wire sub_round = sub_g & (sub_stk | msub_sh[0]);
    wire [7:0] m_sub = msub_sh[6:0] + (sub_round ? 8'd1 : 8'd0);
    wire sub_renorm = m_sub[7];

    wire signed [8:0] exp_out_biased = E_r + 9'sd127;

    always @(*) begin
        if (a_nan || b_nan) begin
            y = a_nan ? {a_s, 8'hFF, (a_m | 7'h40)}
                      : {b_s, 8'hFF, (b_m | 7'h40)};
        end else if (a_inf && b_inf) begin
            y = (a_s == b_s) ? {a_s, 8'hFF, 7'd0} : 16'h7FC0;
        end else if (a_inf || b_inf) begin
            y = {a_inf ? a_s : b_s, 8'hFF, 7'd0};
        end else if (result_zero) begin
            y = (a_s && b_s) ? 16'h8000 : 16'h0000;
        end else if (is_inf) begin
            y = {cneg, 8'hFF, 7'd0};
        end else if (is_sub) begin
            y = sub_renorm ? {cneg, 8'h01, 7'd0} : {cneg, 8'd0, m_sub[6:0]};
        end else begin
            y = {cneg, exp_out_biased[7:0], frac_r};
        end
    end
endmodule