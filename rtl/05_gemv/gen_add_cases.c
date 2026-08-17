/* gen_add_cases.c — 生成 f32_add 的对照用例：随机 + 边界向量。
 *
 * 每行输出两个 fp32 的位模式（a 空格 b），expected 由 C 的 IEEE fp32 加法
 * 算出（-ffp-contract=off，与 RTL 同语义）。TB 逐位比对。
 * 边界覆盖：±0、±inf、NaN、次正规、对消、RN-even 关键点（2^23 边界、尾数
 * 溢出进位）、指数差 1/24/25（sticky 边界）。
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

static uint32_t f32_bits(float v)
{
    uint32_t u; memcpy(&u, &v, 4); return u;
}

int main(int argc, char **argv)
{
    const char *a_out = "add_pairs_a.hex";
    const char *b_out = "add_pairs_b.hex";
    const char *exp_out = "add_expected.hex";
    FILE *fa = fopen(a_out, "w");
    FILE *fb = fopen(b_out, "w");
    FILE *fe = fopen(exp_out, "w");
    if (!fa || !fb || !fe) return 2;

    /* 边界向量（位模式直接写，避免依赖平台构建 NaN 形式） */
    const uint32_t edge[] = {
        0x00000000, 0x80000000,             /* +0, -0 */
        0x3f800000, 0xbf800000,             /* +1, -1 */
        0x3f800000, 0x3f800000,             /* 1+1=2 */
        0x7f800000, 0xff800000,             /* +inf, -inf */
        0x7f800000, 0x7f800000,             /* inf+inf */
        0x7f800000, 0xff800000,             /* inf-inf = NaN */
        0x7fc00000, 0x3f800000,             /* NaN + 1 */
        0x00000001, 0x00000001,             /* 次正规 2^-149 + 同 */
        0x007fffff, 0x007fffff,             /* 最大次正规和（进位到 2^-126） */
        0x00000001, 0x3f800000,             /* 次正规 + 1（sticky） */
        0x3f7fffff, 0x3f800000,             /* 1-2^-24 + 1 = 2（尾数进位） */
        0x4b7fffff, 0x4b800000,             /* 大数进位 */
        0x3e800000, 0x00000001,             /* 指数差 24 → sticky 边界 */
        0x3e800000, 0x00000002,             /* 指数差 23 → 次正规参与 */
        0x7f7fffff, 0x7f7fffff,             /* 最大正规和 → inf */
        0xff7fffff, 0xff7fffff,             /* 最大负正规和 → -inf */
        0x80000000, 0x00000001,             /* -0 + 次正规 */
        0x3f800000, 0xbf7fffff,             /* 1 + (1-2^-24) 差小 → 对消 */
        0x00000000, 0x00000000,             /* 0+0 */
        0x80000000, 0x80000000,             /* -0 + -0 → -0 */
        0x00000001, 0x80000001,             /* 次正规 正负 对消 → +0 */
        0x40000000, 0xc0000000,             /* 2 + -2 → +0（RN 对消） */
    };
    const int nedge = sizeof(edge) / sizeof(edge[0]);

    for (int i = 0; i < nedge; i += 2) {
        float a, b; memcpy(&a, &edge[i], 4); memcpy(&b, &edge[i + 1], 4);
        float s = a + b;
        fprintf(fa, "%08x\n", edge[i]);
        fprintf(fb, "%08x\n", edge[i + 1]);
        fprintf(fe, "%08x\n", f32_bits(s));
    }

    /* 随机向量：全随机 + 加偏（指数偏小/大，多打次正规） */
    for (int i = 0; i < 20000; i++) {
        uint32_t ua, ub;
        if (i % 5 == 0) {                       /* 强制小指数 → 常出次正规 */
            ua = (next_u32() & 0x000FFFFF) | 0x3E000000u;
            ub = (next_u32() & 0x0000FFFF) | 0x00010000u;
        } else if (i % 7 == 0) {                /* 大指数 */
            ua = (next_u32() & 0x7FFFFF) | 0x7E800000u;
            ub = (next_u32() & 0x7FFFFF) | 0x7E800000u;
        } else {
            ua = next_u32();
            ub = next_u32();
        }
        /* 偶发塞 NaN/inf/零 */
        if (i % 101 == 0) ub = 0x7f800000u;
        if (i % 137 == 0) ua = 0x00000000u;
        if (i % 151 == 0) ua = 0x7fc00000u;
        float a, b; memcpy(&a, &ua, 4); memcpy(&b, &ub, 4);
        float s = a + b;
        fprintf(fa, "%08x\n", ua);
        fprintf(fb, "%08x\n", ub);
        fprintf(fe, "%08x\n", f32_bits(s));
    }

    fclose(fa); fclose(fb); fclose(fe);
    int total = nedge / 2 + 20000;
    printf("wrote %s %s %s  total=%d\n", a_out, b_out, exp_out, total);
    return 0;
}
