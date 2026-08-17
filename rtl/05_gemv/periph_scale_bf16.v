`timescale 1ns/1ps
// 05_gemv — 数字外围：bf16 × 2^(sb-127)（E8M0 尺度），精确的 2 幂乘
//
// 版本 B（流片目标）的 scale 单元。语义同 periph_scale.v，输入 q 是 bf16
// （1+8+7）。bf16 指数域同 fp32（8 位，偏置 127），故溢出/次正规边界与
// fp32 版一致，仅有效数 24→8 位 → 桶移/前导零/次正规路径大幅缩小。
// 与 C 参考（pim_mxfp4_periph_acc 的 ldexpf）逐位对齐。
module periph_scale_bf16 (
    input  wire [15:0] q,           // 组段部分和（bf16 位模式）
    input  wire [7:0]  sb,          // E8M0 码 = 2^(sb-127)
    output wire [15:0] p            // q × 2^(sb-127)（bf16 位模式）
);
    wire        s   = q[15];
    wire [7:0]  qe  = q[14:7];
    wire [6:0]  qm  = q[6:0];

    wire q_nan  = (qe == 8'hFF) && (qm != 0);
    wire q_inf  = (qe == 8'hFF) && (qm == 0);
    wire q_zero = (qe == 0) && (qm == 0);

    // 8 位有效数（隐含位）与无偏指数
    wire [7:0]  sig8 = q_zero ? 8'd0
                     : (qe == 0) ? {1'b0, qm}
                     : {1'b1, qm};
    // 指数运算宽 10 位 signed：en 最小 -133，k 最小 -127，
    // e2 最小 -260（超出 9 位 signed -256 下界 → 必须 10 位）。
    wire signed [9:0] e = (qe == 0) ? -10'sd126
                        : $signed({2'b00, qe}) - 10'sd127;

    reg [3:0]  nz;
    always @(*) begin
        nz = 4'd8;
        if (sig8[7])      nz = 4'd0;
        else if (sig8[6]) nz = 4'd1;
        else if (sig8[5]) nz = 4'd2;
        else if (sig8[4]) nz = 4'd3;
        else if (sig8[3]) nz = 4'd4;
        else if (sig8[2]) nz = 4'd5;
        else if (sig8[1]) nz = 4'd6;
        else if (sig8[0]) nz = 4'd7;
    end
    wire [7:0] sig = sig8 << nz;
    wire signed [9:0] en = e - $signed({1'b0, nz});

    wire signed [9:0] k = $signed({1'b0, sb}) - 10'sd127;
    wire signed [9:0] e2 = en + k;

    // 次正规路径：R = -(e2+126) ≥ 1。sig 8 位，R 封顶 150。
    wire signed [9:0] R = -e2 - 10'sd126;
    wire [7:0]  Rc = (R > 10'd150) ? 8'd150 : R[7:0];
    wire [7:0]  ms = (Rc >= 8) ? 8'd0 : sig >> Rc;
    wire g  = (Rc == 0 || Rc >= 9) ? 1'b0 : sig[Rc - 8'd1];
    wire r  = (Rc <= 1 || Rc > 9)  ? 1'b0 : sig[Rc - 8'd2];
    wire stk = (Rc <= 2) ? 1'b0
             : (Rc >= 9) ? |sig
             : |(sig & ((8'h1 << (Rc - 8'd2)) - 8'd1));
    wire round_up = g & (r | stk | ms[0]);
    wire [7:0] m23 = ms + (round_up ? 8'd1 : 8'd0);
    wire sub_carry = m23[7];

    wire [6:0] sub_m = sub_carry ? 7'd0 : m23[6:0];
    wire [7:0]  sub_e = sub_carry ? 8'd1 : 8'd0;

    wire sub_zero = (m23 == 0);
    wire [7:0] norm_e = e2 + 10'sd127;

    wire [15:0] p_nan  = {s, 8'hFF, (qm | 7'h40)};
    wire [15:0] p_inf  = {s, 8'hFF, 7'd0};
    wire [15:0] p_zero = {s, 15'd0};
    wire [15:0] p_sub  = sub_zero ? p_zero : {s, sub_e, sub_m};
    wire [15:0] p_norm = {s, norm_e[7:0], sig[6:0]};

    assign p = q_nan  ? p_nan
             : q_inf  ? p_inf
             : q_zero ? p_zero
             : (sb == 8'hFF) ? 16'h0000
             : (e2 > 10'sd127) ? p_inf
             : (e2 < -10'sd126) ? p_sub
             : p_norm;
endmodule