/* gen_add_cases.c — 生成 f32_add 的对照用例：随机 + 边界向量。
 *
 * 每行输出两个 fp32 的位模式（a 空格 b），expected 由 arm_fadd() 算出：
 * 正常路径用 C 原生加法，NaN/inf 显式实现 ARM FADD 语义（传播第二个 NaN
 * 操作数，inf-inf 符号跟随 b）。这样无论在哪台机器上编译，expected 一致。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint32_t rng = 0xC0FFEEu;
static uint32_t next_u32(void)
{
    rng = rng * 1664525u + 1013904223u;
    return rng;
}

static uint32_t arm_fadd(uint32_t ua, uint32_t ub)
{
    int a_nan = (ua & 0x7f800000u) == 0x7f800000u && (ua & 0x007fffffu);
    int b_nan = (ub & 0x7f800000u) == 0x7f800000u && (ub & 0x007fffffu);
    int a_inf = (ua & 0x7f800000u) == 0x7f800000u && !(ua & 0x007fffffu);
    int b_inf = (ub & 0x7f800000u) == 0x7f800000u && !(ub & 0x007fffffu);

    if (a_nan || b_nan) {
        uint32_t src = b_nan ? ub : ua;
        return src | 0x00400000u;  /* 静默 SNaN：bit22=1 */
    }
    if (a_inf && b_inf) {
        return (ua == ub) ? ua : (ub & 0x80000000u) | 0x7fc00000u;
    }
    if (a_inf || b_inf) {
        return a_inf ? ua : ub;
    }
    float a, b, s;
    memcpy(&a, &ua, 4); memcpy(&b, &ub, 4);
    s = a + b;
    uint32_t u; memcpy(&u, &s, 4);
    return u;
}

int main(int argc, char **argv)
{
    (void)argc; (void)argv;
    const char *a_out = "add_pairs_a.hex";
    const char *b_out = "add_pairs_b.hex";
    const char *exp_out = "add_expected.hex";
    FILE *fa = fopen(a_out, "w");
    FILE *fb = fopen(b_out, "w");
    FILE *fe = fopen(exp_out, "w");
    if (!fa || !fb || !fe) return 2;

    const uint32_t edge[] = {
        0x00000000, 0x80000000,
        0x3f800000, 0xbf800000,
        0x3f800000, 0x3f800000,
        0x7f800000, 0xff800000,
        0x7f800000, 0x7f800000,
        0x7f800000, 0xff800000,
        0x7fc00000, 0x3f800000,
        0x00000001, 0x00000001,
        0x007fffff, 0x007fffff,
        0x00000001, 0x3f800000,
        0x3f7fffff, 0x3f800000,
        0x4b7fffff, 0x4b800000,
        0x3e800000, 0x00000001,
        0x3e800000, 0x00000002,
        0x7f7fffff, 0x7f7fffff,
        0xff7fffff, 0xff7fffff,
        0x80000000, 0x00000001,
        0x3f800000, 0xbf7fffff,
        0x00000000, 0x00000000,
        0x80000000, 0x80000000,
        0x00000001, 0x80000001,
        0x40000000, 0xc0000000,
    };
    const int nedge = sizeof(edge) / sizeof(edge[0]);

    for (int i = 0; i < nedge; i += 2) {
        uint32_t ue = arm_fadd(edge[i], edge[i+1]);
        fprintf(fa, "%08x\n", edge[i]);
        fprintf(fb, "%08x\n", edge[i+1]);
        fprintf(fe, "%08x\n", ue);
    }

    for (int i = 0; i < 20000; i++) {
        uint32_t ua, ub;
        if (i % 5 == 0) {
            ua = (next_u32() & 0x000FFFFF) | 0x3E000000u;
            ub = (next_u32() & 0x0000FFFF) | 0x00010000u;
        } else if (i % 7 == 0) {
            ua = (next_u32() & 0x7FFFFF) | 0x7E800000u;
            ub = (next_u32() & 0x7FFFFF) | 0x7E800000u;
        } else {
            ua = next_u32();
            ub = next_u32();
        }
        if (i % 101 == 0) ub = 0x7f800000u;
        if (i % 137 == 0) ua = 0x00000000u;
        if (i % 151 == 0) ua = 0x7fc00000u;
        uint32_t ue = arm_fadd(ua, ub);
        fprintf(fa, "%08x\n", ua);
        fprintf(fb, "%08x\n", ub);
        fprintf(fe, "%08x\n", ue);
    }

    fclose(fa); fclose(fb); fclose(fe);
    int total = nedge / 2 + 20000;
    printf("wrote %s %s %s  total=%d\n", a_out, b_out, exp_out, total);
    return 0;
}
