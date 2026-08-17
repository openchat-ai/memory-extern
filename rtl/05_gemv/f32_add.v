`timescale 1ns/1ps
// 05_gemv — 内存侧数字外围：fp32 加法器（IEEE-754 RN，逐位同 C）
//
// 内存计算单元"跨组 fp32 累加"的原子操作（sim_cim.c:9 设备语义）：
//   y[r] = fp32 顺序累加 Σ_g (q[r][g] × 2^(sb-127))
// 乘 2 的幂是精确的（指数加法，periph_mac.v），唯一的舍入点就是这里——
// 一个真正的 IEEE 单精度加法器。
//
// 结构（教科书式，一次舍入）：
//   解码 → 对齐（26 位尾数，含 2 个 guard 位 + sticky）→ 加/减 → 规格化
//   → RN-even 舍入（guard/round/sticky）→ 组装（正规/次正规/±inf/±0/NaN）
//
// 值 = m26 × 2^(e-25)，m26 = {1.mantissa, 2'b00}（24+2 位，首 1 在 bit25）。
module f32_add (
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    wire       a_s = a[31], b_s = b[31];
    wire [7:0] a_e = a[30:23], b_e = b[30:23];
    wire [22:0] a_m = a[22:0], b_m = b[22:0];

    wire a_nan = (a_e == 8'hFF) && (a_m != 0);
    wire b_nan = (b_e == 8'hFF) && (b_m != 0);
    wire a_inf = (a_e == 8'hFF) && (a_m == 0);
    wire b_inf = (b_e == 8'hFF) && (b_m == 0);
    wire a_zero = (a_e == 0) && (a_m == 0);
    wire b_zero = (b_e == 0) && (b_m == 0);

    // 无偏指数：正规 e=exp-127；次正规 e=-126；零 e=-127（保证最小）
    wire signed [8:0] a_eu = a_zero ? -9'sd127
                          : (a_e == 0) ? -9'sd126
                          : $signed({1'b0, a_e}) - 9'sd127;
    wire signed [8:0] b_eu = b_zero ? -9'sd127
                          : (b_e == 0) ? -9'sd126
                          : $signed({1'b0, b_e}) - 9'sd127;
    // 26 位尾数（含 2 guard 位）。正规隐含位=1，次正规隐含位=0，零=全 0。
    // 值 = m26 × 2^(e-25)：正规 = 1.a_m×2^e ✓；次正规 = 0.a_m×2^-126 = a_m×2^-149 ✓
    wire [25:0] a_m26 = a_zero ? 26'd0 : {(a_e != 0), a_m, 2'b00};
    wire [25:0] b_m26 = b_zero ? 26'd0 : {(b_e != 0), b_m, 2'b00};

    wire same_sign = (a_s == b_s);
    wire hi_a = (a_eu > b_eu);

    wire signed [8:0] eh = hi_a ? a_eu : b_eu;
    wire [25:0] mh = hi_a ? a_m26 : b_m26;
    wire [25:0] ml = hi_a ? b_m26 : a_m26;
    wire [8:0]  dif = hi_a ? (a_eu - b_eu) : (b_eu - a_eu);

    // 对齐：小尾数右移 dif（截断 >26，只剩 sticky）
    wire [8:0] difc = (dif > 9'd26) ? 9'd26 : dif;
    wire [25:0] ml_sh = (ml >> difc);
    wire [25:0] lowmask = (difc == 9'd0) ? 26'd0
                        : (difc == 9'd26) ? 26'h3FF_FFFF
                        : (26'h1 << difc) - 26'd1;
    wire stk = (difc != 0) && (|(ml & lowmask));

    // 加/减
    reg [26:0] msum;
    reg        cneg;
    always @(*) begin
        if (same_sign) begin
            msum = {1'b0, mh} + {1'b0, ml_sh};
            cneg = a_s;
        end else if (mh >= ml_sh) begin
            msum = {1'b0, mh} - {1'b0, ml_sh} - (stk ? 27'd1 : 27'd0);  // 借位
            cneg = hi_a ? a_s : b_s;
        end else begin
            msum = {1'b0, ml_sh} - {1'b0, mh};
            cneg = hi_a ? b_s : a_s;
        end
    end

    // 进位：msum[26] 置位时整体右移 1（进位到 bit25），指数 +1。
    // 之后首 1 至多在 bit25，与输入解码的 1.m×2^e 约定一致。
    wire [26:0] ms1 = msum[26] ? (msum >> 1) : msum;
    wire signed [8:0] E0 = eh + (msum[26] ? 9'sd1 : 9'sd0);

    // 规格化：把首 1 移到 bit25。值 = mnorm × 2^(E0-nz-25)，E = E0 - nz。
    // 先做前导零计数（26 位优先级编码 → 5 位 nz，全零 → 27），再单次桶形移位。
    // 相比 27 级 if-级联（每级都算一次完整移位），面积与深度均为对数级。
    // 注：ms1[26] 恒为 0（进位已在 ms1 = msum[26] ? msum>>1 : msum 消化）。
    reg [4:0] nz;
    always @(*) begin
        nz = 5'd27;
        if      (ms1[25]) nz = 5'd0;
        else if (ms1[24]) nz = 5'd1;
        else if (ms1[23]) nz = 5'd2;
        else if (ms1[22]) nz = 5'd3;
        else if (ms1[21]) nz = 5'd4;
        else if (ms1[20]) nz = 5'd5;
        else if (ms1[19]) nz = 5'd6;
        else if (ms1[18]) nz = 5'd7;
        else if (ms1[17]) nz = 5'd8;
        else if (ms1[16]) nz = 5'd9;
        else if (ms1[15]) nz = 5'd10;
        else if (ms1[14]) nz = 5'd11;
        else if (ms1[13]) nz = 5'd12;
        else if (ms1[12]) nz = 5'd13;
        else if (ms1[11]) nz = 5'd14;
        else if (ms1[10]) nz = 5'd15;
        else if (ms1[9])  nz = 5'd16;
        else if (ms1[8])  nz = 5'd17;
        else if (ms1[7])  nz = 5'd18;
        else if (ms1[6])  nz = 5'd19;
        else if (ms1[5])  nz = 5'd20;
        else if (ms1[4])  nz = 5'd21;
        else if (ms1[3])  nz = 5'd22;
        else if (ms1[2])  nz = 5'd23;
        else if (ms1[1])  nz = 5'd24;
        else if (ms1[0])  nz = 5'd25;
        // 全零：nz 保持 27，桶移自动归零
    end
    wire [26:0] mnorm = ms1 << nz;          // 单次桶移；全零时 <<27 = 0

    wire signed [8:0] E = E0 - $signed({1'b0, nz[4:0]});   // 结果无偏指数

    wire result_zero = (msum == 27'd0);

    // 正规路径：mnorm 首 1 在 bit25 → 1.f×2^E。f = mnorm[24:2]（23 位），
    // guard = mnorm[1], round = mnorm[0], sticky = stk。
    wire g = mnorm[1];
    wire r = mnorm[0];
    wire s = stk | (msum[26] ? msum[0] : 1'b0);    // 进位右移丢弃的 msum[0] 并入 sticky
    wire lsb = mnorm[2];
    wire round_up = g & (r | s | lsb);                 // RN-even
    wire [23:0] frac_plus = {1'b0, mnorm[24:2]} + (round_up ? 24'd1 : 24'd0);
    wire carry = frac_plus[23];                            // 尾数进位（bit23 溢出）
    wire signed [8:0] E_r = E + (carry ? 9'sd1 : 9'sd0);
    wire [22:0] frac_r = carry ? 23'd0 : frac_plus[22:0];

    // 溢出/次正规判定用舍入后的指数（E_r）。
    wire is_inf = !result_zero && (E_r > 9'sd127);     // exp 域 ≥255 → ±inf
    wire is_sub = !result_zero && !is_inf && (E < -9'sd126);

    // 次正规路径：值 = m×2^-149，m 23 位。m = mnorm × 2^(E+124)，右移 R = -E-124。
    wire signed [8:0] R = -E - 9'sd124;                 // E<-126 → R≥2
    wire [8:0] Rc = (R > 9'd150) ? 9'd150 : R;
    wire [26:0] msub_sh = (mnorm >> Rc);
    wire [8:0] Rm1 = (Rc == 9'd0) ? 9'd0 : (Rc - 9'd1);
    wire [25:0] sub_lowmask = (Rc == 9'd0) ? 26'd0
                            : (Rc >= 9'd26) ? 26'h3FF_FFFF
                            : (26'h1 << Rm1) - 26'd1;
    wire sub_g = (Rc == 9'd0) ? 1'b0 : mnorm[Rc - 9'd1];
    wire sub_stk = stk | ((Rc > 9'd0) && (|(mnorm & sub_lowmask)));
    wire sub_round = sub_g & (sub_stk | msub_sh[0]);
    wire [23:0] m_sub = msub_sh[22:0] + (sub_round ? 24'd1 : 24'd0);
    wire sub_renorm = m_sub[23];                        // 进位顶到正规下界（min normal）

    // 正规结果的偏置指数（E_r + 127）
    wire signed [8:0] exp_out_biased = E_r + 9'sd127;

    always @(*) begin
        if (a_nan || b_nan) begin
            // C（ARM FADD）传播第一个 NaN 操作数，SNaN 静默化（mantissa bit22 置 1）
            y = a_nan ? {a_s, 8'hFF, (a_m | 23'h400000)}
                      : {b_s, 8'hFF, (b_m | 23'h400000)};
        end else if (a_inf && b_inf) begin
            y = (a_s == b_s) ? {a_s, 8'hFF, 23'd0} : 32'h7FC0_0000;
        end else if (a_inf || b_inf) begin
            y = {a_inf ? a_s : b_s, 8'hFF, 23'd0};
        end else if (result_zero) begin
            y = (a_s && b_s) ? 32'h8000_0000 : 32'h0000_0000;   // ±0：仅 (-0)+(-0)=-0
        end else if (is_inf) begin
            y = {cneg, 8'hFF, 23'd0};
        end else if (is_sub) begin
            y = sub_renorm ? {cneg, 8'h01, 23'd0} : {cneg, 8'd0, m_sub[22:0]};
        end else begin
            y = {cneg, exp_out_biased[7:0], frac_r};
        end
    end
endmodule
