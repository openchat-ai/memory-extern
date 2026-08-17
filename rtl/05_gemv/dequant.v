`timescale 1ns/1ps
// 04_dequant — 内存侧 MXFP4 去量化（对照 pim/ 黄金参考逐位对齐）
//
// 北极星：LLM 权重住进内存设备。内存计算单元只做 y=dequant(W)·x，
// 去量化（E2M1 码 × E8M0 scale → fp32）是它的第一步，必须在内存侧做。
//
// 本课的关键洞察（让去量化不用浮点乘法器）：
//   E2M1 值集 {0, ±0.5, ±1, ±1.5, ±2, ±3, ±4, ±6} 里，非零值全部是
//   二进制 1.0 或 1.1 × 2^e，e ∈ {-1, 0, 1, 2}：
//     0.5 = 1.0×2^-1    1.5 = 1.1×2^0    3.0 = 1.1×2^1    6.0 = 1.1×2^2
//     1.0 = 1.0×2^0     2.0 = 1.0×2^1    4.0 = 1.0×2^2
//   E8M0 = 2^(sb-127)，所以"值×scale"的 fp32 位模式是：
//     sign     = 码[3]
//     exponent = sb + e              ← 纯整数加法
//     mantissa = 0x000000(1.0) 或 0x400000(1.1)   ← 查 m 的奇偶
//   零（nib==0）和 NaN scale（sb==255）都归 ±0.0，符号跟随码。
//
// 与 C 参考 pim_mxfp4_dequant 逐位对齐，已用真实 checkpoint 字节验证 0 失配。
// 注意：这是"内存侧"的语义 —— 喂进来的是一对打包字节里的一个 nibble。
module dequant (
    input  wire [7:0] pbyte,      // 一个打包字节（含两个 E2M1 码）
    input  wire       nib_sel,    // 0=低半字节（偶元素）  1=高半字节（奇元素）
    input  wire [7:0] scale,      // E8M0 码（2^(sb-127)）
    output wire [31:0] fp32       // 去量化结果（位模式，逐位同 C 参考）
);
    wire [3:0] nib   = nib_sel ? pbyte[7:4] : pbyte[3:0];
    wire       sign  = nib[3];
    wire [2:0] m     = nib[2:0];

    // e = (m-2)>>1（算术右移）：m:1→-1, 2→0, 3→0, 4→1, 5→1, 6→2, 7→2
    wire signed [3:0] es = $signed({1'b0, m}) - 4'd2;
    wire signed [3:0] e  = es >>> 1;

    // 1.1b 尾数只在 m ∈ {3,5,7}：m 为奇且 m≠1
    wire [22:0] mant = (m[0] && (m != 3'd1)) ? 23'h400000 : 23'h000000;

    // 指数 = sb + e。e 为有符号 {-1,0,1,2}，必须让整个加法按有符号运算，
    // 否则 {1'b0,scale}(无符号) 会把 e 零扩展成 +15（-1→0xF 变 +15），这就是之前
    // 看到的偏移 bug。
    wire signed [9:0] expf = {2'b0, scale} + $signed({{6{e[3]}}, e});

    // 边界处理（covered by edge TB，见回归）：
    //   expf ≥ 255 → 溢出 → ±Inf（C 参考 ldexpf 得上溢，位模式 0x7F800000/0xFF800000）
    //   expf ≤ 0   → 下溢到次正规区。次正规浮点 = 分数 × 2^-149，
    //               值 = M×2^(expf-127)（M∈{1.0,1.5}）→ 分数 = 1.0→0x400000 / 1.5→0x600000
    //               ，右移 (-expf) 位（此时最高位 ≤2^22，不丢位）
    wire ovf = expf >= 255;
    wire [22:0] sfrac = (mant == 0 ? 23'h400000 : 23'h600000) >> (-expf);   // 次正规尾数
    wire [31:0] subn  = {sign, 8'h0, sfrac};

    assign fp32 = (m == 0 || scale == 8'hFF)
                ? (sign ? 32'h8000_0000 : 32'h0000_0000)   // ±0.0
                : ovf
                  ? (sign ? 32'hFF80_0000 : 32'h7F80_0000) // ±Inf
                  : (expf <= 0)
                    ? subn
                    : {sign, expf[7:0], mant};
endmodule
