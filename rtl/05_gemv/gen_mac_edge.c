/* gen_mac_edge.c — periph_mac 定向边界 fixture（对照 C golden pim_mxfp4_periph_acc）。
 *
 * 真实 fixture 的 scale 全在 120-122、q 无 NaN/inf，测不到：
 *   - scale==255（跳过贡献 0）
 *   - 累加链中途 ±Inf/NaN 的传播
 *   - 次正规乘积、次正规 + 正规混合
 *   - +0/-0 起点语义与对消
 *   - 乘积/累加溢出到 ±Inf
 * 本生成器直接复用 pim/mxfp4_gemv.c 的 pim_mxfp4_periph_acc（设备侧 golden）
 * 计算 expected，与上一课同样"逐位对齐 C"。输出 rows×NGRP 的 q.hex/scale.hex
 * 与 rows 行的 expected.hex。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void pim_mxfp4_periph_acc(float *y, const float *q, const uint8_t *scales,
                          int rows, int ngrp);

#define NGRP 8
#define ROWS 48

static uint32_t rng = 0xC0FFEEu;
static uint32_t next_u32(void)
{
    rng = rng * 1664525u + 1013904223u;
    return rng;
}
static uint32_t f32_bits(float v)
{
    uint32_t u; memcpy(&u, &v, 4); return u;
}
static float pick_f32(uint32_t bits)
{
    float v; memcpy(&v, &bits, 4); return v;
}

int main(void)
{
    float q[ROWS][NGRP];
    uint8_t sc[ROWS][NGRP];

    for (int r = 0; r < ROWS; r++)
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = 0.0f;
            sc[r][g] = 0;
        }

    /* ---- 定向行 ---- */
    /* r0: scale==255 全部跳过 → 结果 +0（C 的 acc=0.0f 起点） */
    for (int g = 0; g < NGRP; g++) sc[0][g] = 255;

    /* r1: 第 3 组 scale==255，其余 scale=127（乘 1） */
    {
        int r = 1;
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = 1.5f;
            sc[r][g] = (g == 2) ? 255 : 127;
        }
    }
    /* r2: 全次正规乘积：scale=120，q 为小尾数 → term 落入次正规 */
    {
        int r = 2;
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = pick_f32(0x00000010u + 32u * g);   /* 小次正规 */
            sc[r][g] = 120;
        }
    }
    /* r3: 次正规 + 正规混合，正负交替（对消） */
    {
        int r = 3;
        static const uint32_t qb[8] = {
            0x3f800000, 0xbf800000, 0x3f800000, 0xbf800000,
            0x3f800000, 0xbf800000, 0x3f800000, 0xbf800000,
        };                                     /* 1 -1 1 -1 ... 对消 → +0 */
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = pick_f32(qb[g]);
            sc[r][g] = 127;
        }
    }
    /* r4: 中途 ±Inf → 结果 ±Inf；之后再加 ±Inf/有限 */
    {
        int r = 4;
        q[r][0] = 1.0f; sc[r][0] = 127;
        q[r][1] = pick_f32(0x7f800000u); sc[r][1] = 127;   /* +inf */
        q[r][2] = 2.5f;  sc[r][2] = 127;
        q[r][3] = pick_f32(0x7f800000u); sc[r][3] = 127;   /* +inf+inf=+inf */
        q[r][4] = -1.0f; sc[r][4] = 127;
    }
    /* r5: 中途 -Inf，随后加 +inf（异号 inf）→ NaN */
    {
        int r = 5;
        q[r][0] = pick_f32(0xff800000u); sc[r][0] = 127;   /* -inf */
        q[r][1] = pick_f32(0x7f800000u); sc[r][1] = 127;   /* +inf → NaN */
        q[r][2] = 3.0f;  sc[r][2] = 127;                   /* NaN+3 = NaN */
    }
    /* r6: qNaN 与 sNaN 通过累加链传播（第一 NaN 操作数） */
    {
        int r = 6;
        q[r][0] = 1.0f;  sc[r][0] = 127;
        q[r][1] = pick_f32(0x7fc00000u); sc[r][1] = 127;   /* NaN 卡在累加器 */
        q[r][2] = 4.0f;  sc[r][2] = 127;
        q[r][3] = pick_f32(0x7fa00000u); sc[r][3] = 127;   /* sNaN */
    }
    /* r7: 乘积溢出：q 大 + scale 大 → ±inf；再 + 大有限 */
    {
        int r = 7;
        q[r][0] = pick_f32(0x7f7fffffu); sc[r][0] = 128;    /* max × 2 → +inf */
        q[r][1] = pick_f32(0x7f7fffffu); sc[r][1] = 127;
        q[r][2] = -2.0f;  sc[r][2] = 127;
    }
    /* r8: -0 起点/贡献：全 -0 组、-0 + +0 */
    {
        int r = 8;
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = pick_f32(0x80000000u);
            sc[r][g] = 127;
        }                                   /* -0 -0 ... = -0 */
    }
    /* r9: 交替 +0/-0（RN：+0 + -0 = +0） */
    {
        int r = 9;
        for (int g = 0; g < NGRP; g++)
            q[r][g] = pick_f32((g & 1) ? 0x80000000u : 0x00000000u);
        for (int g = 0; g < NGRP; g++) sc[r][g] = 127;
    }
    /* r10: 对消到精确零（x + -x 于中间）→ +0 继续累加 */
    {
        int r = 10;
        q[r][0] = 3.5f; sc[r][0] = 127;
        q[r][1] = -3.5f; sc[r][1] = 127;    /* → +0 */
        q[r][2] = 5.0f; sc[r][2] = 127;
    }
    /* r11: 大累加溢出（单调同号 → 正和，中途→max，最后→inf） */
    {
        int r = 11;
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = pick_f32(0x7f7fffffu);
            sc[r][g] = 120;                  /* 大有限 × 2^-7，仍 sinf 域 */
        }
    }
    /* r12: 次正规精确表示（scale 使 q 数的乘积 = 2^-149 精确） */
    {
        int r = 12;
        q[r][0] = 1.0f; sc[r][0] = 22;       /* 2^(22-127)=2^-105 → 正规*/
        q[r][1] = 1.0f; sc[r][1] = 23;       /* 2^-104 */
        q[r][2] = 1.0f; sc[r][2] = -1 + 127; /* E8M0: 126 → 2^-1 = 0.5 */
        q[r][3] = pick_f32(0x00000001u); sc[r][3] = 127; /* 2^-149 精确 */
    }
    /* r13: 负次正规乘积和（刚修的符号路径在 MAC 里的回归） */
    {
        int r = 13;
        q[r][0] = pick_f32(0x8049ea62u); sc[r][0] = 120;   /* 负次正规 */
        q[r][1] = pick_f32(0x0023f37cu); sc[r][1] = 120;   /* 正次正规对消 → 负次正规 */
        q[r][2] = pick_f32(0x00000001u); sc[r][2] = 127;
    }
    /* r14: 全部五类 E8M0 常规 scale 混合（120-124） + 稀疏 NaN */
    {
        int r = 14;
        static const uint8_t sb[8] = { 120, 121, 122, 123, 124, 125, 126, 127 };
        for (int g = 0; g < NGRP; g++) {
            q[r][g] = (g & 1) ? -1.25f : 2.0f;
            sc[r][g] = sb[g];
        }
        sc[r][3] = 255;                     /* 穿插跳过 */
    }

    /* r15..: 随机（含随机 q 随机 scale，含 NaN/inf/零） */
    for (int r = 15; r < ROWS; r++) {
        for (int g = 0; g < NGRP; g++) {
            uint32_t u = next_u32();
            /* 让 scale 分布偏常规但混入 255 与极值 */
            uint8_t s = (uint8_t)(next_u32() & 0xFF);
            q[r][g] = pick_f32(u);
            sc[r][g] = (g == 0 || g == NGRP / 2) ? s : (uint8_t)(120 + (s % 8));
            if ((g & 3) == 3) sc[r][g] = 255;   /* 每 4 组一个 255 */
        }
    }

    /* 计算 expected（C golden）并写出 */
    FILE *fq = fopen("edge_q.hex", "w");
    FILE *fs = fopen("edge_scale.hex", "w");
    FILE *fe = fopen("edge_expected.hex", "w");
    if (!fq || !fs || !fe) return 2;
    float y[ROWS];
    for (int r = 0; r < ROWS; r++)
        pim_mxfp4_periph_acc(&y[r], q[r], sc[r], 1, NGRP);
    for (int r = 0; r < ROWS; r++) {
        for (int g = 0; g < NGRP; g++) {
            fprintf(fq, "%08x\n", f32_bits(q[r][g]));
            fprintf(fs, "%02x\n", sc[r][g]);
        }
        fprintf(fe, "%08x\n", f32_bits(y[r]));
    }
    fclose(fq); fclose(fs); fclose(fe);
    printf("wrote %d 行 x %d 组 (edge fixture)\n", ROWS, NGRP);
    return 0;
}