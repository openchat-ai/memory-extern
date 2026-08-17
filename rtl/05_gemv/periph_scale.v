`timescale 1ns/1ps
// 05_gemv — 数字外围：fp32 × 2^(sb-127)（E8M0 尺度），精确的 2 幂乘
//
// 设备语义（sim_cim.c / pim/mxfp4_gemv.c:103）：组段部分和 q 是 fp32，
// scale 是 E8M0 码（=2^(sb-127)）。"q × 2^k" 是 IEEE 精确操作——
// 幂次乘不改变尾数，只动指数。唯一的舍入点是把结果压回 fp32 位模式时：
//   - e2 > 127     → ±inf（溢出）
//   - e2 < -126    → 次正规（尾数右移 + RN 舍入，可能渐变下溢到 ±0）
//   - 其余         → 正规，尾数原样，指数域 = e2+127
// 与 C 参考逐位对齐（pim_mxfp4_periph_acc 用 ldexpf 复现同一个 IEEE 乘法）。
module periph_scale (
    input  wire [31:0] q,           // ADC 输出组段部分和（fp32 位模式）
    input  wire [7:0]  sb,          // E8M0 码 = 2^(sb-127)
    output wire [31:0] p            // q × 2^(sb-127)（fp32 位模式）
);
    wire       s  = q[31];
    wire [7:0] qe = q[30:23];
    wire [22:0] qm = q[22:0];

    wire q_nan  = (qe == 8'hFF) && (qm != 0);
    wire q_inf  = (qe == 8'hFF) && (qm == 0);
    wire q_zero = (qe == 0) && (qm == 0);

    // 24 位有效数（隐含位：正规=1，次正规=0）与无偏指数
    wire [23:0] sig24 = q_zero ? 24'd0
                      : (qe == 0) ? {1'b0, qm}
                      : {1'b1, qm};
    wire signed [8:0] e = (qe == 0) ? -9'sd126
                        : $signed({1'b0, qe}) - 9'sd127;

    // 归一化：把 sig24 的首 1 移到 bit23（次正规输入的隐含位不在 bit23，
    // 直接套正规输出格式 {s, e2+127, qm} 会错得离谱），指数同步减小。
    // 与 f32_add 同法：前导零计数（24 位优先级编码 → nz）+ 单次桶移，面积对数级。
    reg [4:0]  nz;
    always @(*) begin
        nz = 5'd24;
        if (sig24[23])      nz = 5'd0;
        else if (sig24[22]) nz = 5'd1;
        else if (sig24[21]) nz = 5'd2;
        else if (sig24[20]) nz = 5'd3;
        else if (sig24[19]) nz = 5'd4;
        else if (sig24[18]) nz = 5'd5;
        else if (sig24[17]) nz = 5'd6;
        else if (sig24[16]) nz = 5'd7;
        else if (sig24[15]) nz = 5'd8;
        else if (sig24[14]) nz = 5'd9;
        else if (sig24[13]) nz = 5'd10;
        else if (sig24[12]) nz = 5'd11;
        else if (sig24[11]) nz = 5'd12;
        else if (sig24[10]) nz = 5'd13;
        else if (sig24[9])  nz = 5'd14;
        else if (sig24[8])  nz = 5'd15;
        else if (sig24[7])  nz = 5'd16;
        else if (sig24[6])  nz = 5'd17;
        else if (sig24[5])  nz = 5'd18;
        else if (sig24[4])  nz = 5'd19;
        else if (sig24[3])  nz = 5'd20;
        else if (sig24[2])  nz = 5'd21;
        else if (sig24[1])  nz = 5'd22;
        else if (sig24[0])  nz = 5'd23;
        // 全零：nz 保持 24（桶移自动归零）
    end
    wire [23:0] sig = sig24 << nz;          // 单次桶移；全零时 <<24 = 0
    wire signed [8:0] en = e - $signed({1'b0, nz[4:0]});  // 归一化无偏指数

    wire signed [8:0] k = $signed({1'b0, sb}) - 9'sd127;
    wire signed [8:0] e2 = en + k;

    // 次正规路径：m23 = sig >> R（R = -(e2+126) ≥ 1），RN 舍入。
    // R 可到 150（sig 为 24 位），全部位移出时结果只能舍入到 ±0；
    // g 有效区 R≤24（g=sig[R-1]），r 有效区 R≤25，R≥27 时 sticky=全部位。
    wire signed [8:0] R = -e2 - 9'sd126;
    wire [7:0]  Rc = (R > 9'd150) ? 8'd150 : R[7:0];   // 封顶（>24 全丢弃）
    wire [23:0] ms = (Rc >= 24) ? 24'd0 : sig >> Rc;
    wire g  = (Rc == 0 || Rc >= 25) ? 1'b0 : sig[Rc - 8'd1];
    wire r  = (Rc <= 1 || Rc > 25)  ? 1'b0 : sig[Rc - 8'd2];
    wire stk = (Rc <= 2) ? 1'b0
             : (Rc >= 27) ? |sig
             : |(sig & ((24'h1 << (Rc - 8'd2)) - 24'd1));
    wire round_up = g & (r | stk | ms[0]);
    wire [23:0] m23 = ms + (round_up ? 24'd1 : 24'd0);
    wire sub_carry = m23[23];                          // 进位顶到最小正规

    wire [22:0] sub_m = sub_carry ? 23'd0 : m23[22:0];
    wire [7:0]  sub_e = sub_carry ? 8'd1 : 8'd0;

    wire sub_zero = (m23 == 0);
    wire [7:0] norm_e = e2 + 9'sd127;                    // 1..254（-126 ≤ e2 ≤ 127）

    wire [31:0] p_nan  = {s, 8'hFF, (qm | 23'h400000)};   // 传播 NaN（静默化）
    wire [31:0] p_inf  = {s, 8'hFF, 23'd0};
    wire [31:0] p_zero = {s, 31'd0};
    wire [31:0] p_sub  = sub_zero ? p_zero : {s, sub_e, sub_m};
    wire [31:0] p_norm = {s, norm_e[7:0], sig[22:0]};

    assign p = q_nan  ? p_nan
             : q_inf  ? p_inf
             : q_zero ? p_zero
             : (sb == 8'hFF) ? 32'h0000_0000           // NaN scale：贡献 0（同 C 跳过）
             : (e2 > 9'sd127) ? p_inf
             : (e2 < -9'sd126) ? p_sub
             : p_norm;
endmodule
