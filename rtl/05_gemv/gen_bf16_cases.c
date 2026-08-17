/* gen_bf16_cases.c — 生成 bf16_add 的对照用例：随机 + 边界向量。
 *
 * bf16 = IEEE fp32 结构（1+8+7），转 float 精确；float 相加结果若恰好落在
 * bf16 网格上则 RN 回 bf16 无额外误差（bf16 是 fp32 的子网格，加法结果
 * 在 fp32 里精确舍入到 fp32，再舍入 bf16 与直接算 bf16 等价——但为稳妥
 * 仍用 float 转 bf16 的 C 路径生成 expected，与 RTL 同 IEEE 语义）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

static uint32_t rng = 0xC0FFEEu;
static uint32_t next_u32(void)
{
    rng = rng * 1664525u + 1013904223u;
    return rng;
}

static uint16_t float_to_bf16(float v)
{
    uint32_t u; memcpy(&u, &v, 4);
    /* 按 fp32→bf16 RN-even 舍入 */
    uint16_t h = (u >> 16) & 0xFFFF;
    uint32_t r = u & 0xFFFF;
    /* RN-even: 若剩余>0x8000 进位；==0x8000 且 LSB 为 1 进位 */
    if (r > 0x8000u || (r == 0x8000u && (h & 1)))
        h++;
    return h;
}

static float bf16_to_float(uint16_t h)
{
    uint32_t u = (uint32_t)h << 16;
    float v; memcpy(&v, &u, 4); return v;
}

int main(int argc, char **argv)
{
    const char *a_out = "bf16_pairs_a.hex";
    const char *b_out = "bf16_pairs_b.hex";
    const char *exp_out = "bf16_expected.hex";
    FILE *fa = fopen(a_out, "w");
    FILE *fb = fopen(b_out, "w");
    FILE *fe = fopen(exp_out, "w");
    if (!fa || !fb || !fe) return 2;

    /* 边界向量（bf16 位模式） */
    const uint16_t edge[] = {
        0x0000, 0x8000,                 /* +0, -0 */
        0x3F80, 0xBF80,                 /* +1, -1 */
        0x3F80, 0x3F80,                 /* 1+1 */
        0x3F80, 0xBF80,                 /* 1-1 对消 */
        0x7F80, 0x7F80,                 /* +inf + +inf */
        0x7F80, 0xBF80,                 /* +inf + -inf = NaN */
        0x7F80, 0x3F80,                 /* inf + 1 */
        0x7FC0, 0x3F80,                 /* NaN + 1 */
        0x0001, 0x0001,                 /* min 次正规 ×2 */
        0x0080, 0x0080,                 /* min 正规 2^-126 ×2 */
        0x007F, 0x0080,                 /* 次正规 邻 正规 */
        0x3F7F, 0x3F7F,                 /* 1-2^-8 + 1-2^-8 */
        0x3F80, 0x0080,                 /* 1 + min 正规 */
        0x3F80, 0x0001,                 /* 1 + min 次正规 */
        0x4000, 0x3F80,                 /* 2 + 1 */
        0x477F, 0x477F,                 /* 2^15 - ε + ... */
        0x7F7F, 0x7F7F,                 /* 最大正规 + 自身 */
        0x7F7F, 0x0001,                 /* 最大正规 + 最小次正规 */
    };
    int n_edge = sizeof(edge) / sizeof(edge[0]);

    FILE *tmp = fopen("_bf16_tmp.bin", "wb");
    if (!tmp) return 2;

    /* 边界用例：先直接生成 expected（bf16 位模式） */
    for (int i = 0; i < n_edge; i += 2) {
        uint16_t ah = edge[i], bh = edge[i+1];
        float a = bf16_to_float(ah), b = bf16_to_float(bh);
        float s = a + b;
        uint16_t eh = float_to_bf16(s);
        /* 特判 NaN：C 把 NaN 传播静默化；bf16 需处理 */
        fprintf(fa, "%04x\n", ah);
        fprintf(fb, "%04x\n", bh);
        fprintf(fe, "%04x\n", eh);
    }

    /* 随机用例：30000 组，覆盖全范围 */
    for (int i = 0; i < 30000; i++) {
        /* 生成 bf16：随机指数（含次正规/正规/inf/nan） + 随机尾数 */
        uint32_t e = next_u32() % 256;
        uint32_t m = next_u32() & 0x7F;
        uint32_t sgn = next_u32() & 1;
        uint16_t ah = (sgn << 15) | (e << 7) | m;
        e = next_u32() % 256;
        m = next_u32() & 0x7F;
        sgn = next_u32() & 1;
        uint16_t bh = (sgn << 15) | (e << 7) | m;

        float a = bf16_to_float(ah), b = bf16_to_float(bh);
        float s = a + b;
        uint16_t eh = float_to_bf16(s);

        /* NaN 静默化（C 语义：传播首个 NaN 并置静默位） */
        if ((eh & 0x7F80) == 0x7F80 && (eh & 0x7F)) eh |= 0x40;

        fprintf(fa, "%04x\n", ah);
        fprintf(fb, "%04x\n", bh);
        fprintf(fe, "%04x\n", eh);
    }

    fclose(fa); fclose(fb); fclose(fe); fclose(tmp);
    remove("_bf16_tmp.bin");
    printf("generated bf16 pairs + expected\n");
    return 0;
}
