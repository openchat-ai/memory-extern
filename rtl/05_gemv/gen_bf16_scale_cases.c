/* gen_bf16_scale_cases.c — 生成 periph_scale_bf16 的对照用例。
 *
 * 语义：p = q × 2^(sb-127)，q 为 bf16。C 参考用 ldexpf（乘 2 的幂精确），
 * 结果 RN 回 bf16。边界覆盖：±0/±inf/NaN、次正规、溢出到 inf 的临界点、
 * 下溢到次正规/±0、scale==255(NaN scale → 0)。
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
    uint16_t h = (u >> 16) & 0xFFFF;
    uint32_t r = u & 0xFFFF;
    if (r > 0x8000u || (r == 0x8000u && (h & 1))) h++;
    return h;
}

static float bf16_to_float(uint16_t h)
{
    uint32_t u = (uint32_t)h << 16;
    float v; memcpy(&v, &u, 4); return v;
}

int main(int argc, char **argv)
{
    const char *q_out = "bf16s_q.hex";
    const char *s_out = "bf16s_sb.hex";
    const char *exp_out = "bf16s_exp.hex";
    FILE *fq = fopen(q_out, "w");
    FILE *fs = fopen(s_out, "w");
    FILE *fe = fopen(exp_out, "w");
    if (!fq || !fs || !fe) return 2;

    /* 边界 (q, sb) */
    const uint16_t qedge[] = { 0x0000, 0x8000, 0x3F80, 0xBF80, 0x7F80,
                               0x0080, 0x0001, 0x7F7F, 0x3F7F, 0x4000 };
    const uint8_t  sedge[]  = { 0x7F, 0x80, 0x7E, 0xFF, 0x00, 0x87,
                                0x81, 0x88, 0x7C, 0x78, 0x90, 0xA0 };
    for (size_t i = 0; i < sizeof(qedge)/sizeof(qedge[0]); i++)
        for (size_t j = 0; j < sizeof(sedge)/sizeof(sedge[0]); j++) {
            uint16_t qh = qedge[i];
            uint8_t  sb = sedge[j];
            float    q = bf16_to_float(qh);
            float    p;
            /* 与 RTL (periph_scale.v) 同优先级：q 的特殊形态优先于 scale==FF */
            if (q == 0.0f || isinf(q) || isnan(q)) p = q;   /* 0/±inf/NaN 乘幂不变 */
            else if (sb == 0xFF) p = 0.0f;                  /* NaN scale → 0 */
            else {
                int k = (int)sb - 127;
                p = ldexpf(q, k);
            }
            uint16_t eh = float_to_bf16(p);
            /* NaN 静默化 */
            if ((eh & 0x7F80) == 0x7F80 && (eh & 0x7F)) eh |= 0x40;
            fprintf(fq, "%04x\n", qh);
            fprintf(fs, "%02x\n", sb);
            fprintf(fe, "%04x\n", eh);
        }

    /* 随机：12000 组，q 全覆盖 × sb 全部 */
    for (int i = 0; i < 12000; i++) {
        uint32_t e = next_u32() % 256;
        uint32_t m = next_u32() & 0x7F;
        uint32_t sgn = next_u32() & 1;
        uint16_t qh = (sgn << 15) | (e << 7) | m;
        uint8_t  sb = next_u32() & 0xFF;

        float q = bf16_to_float(qh);
        float p;
        if (q == 0.0f || isinf(q) || isnan(q)) p = q;
        else if (sb == 0xFF) p = 0.0f;
        else {
            int k = (int)sb - 127;
            p = ldexpf(q, k);
        }
        uint16_t eh = float_to_bf16(p);
        if ((eh & 0x7F80) == 0x7F80 && (eh & 0x7F)) eh |= 0x40;
        fprintf(fq, "%04x\n", qh);
        fprintf(fs, "%02x\n", sb);
        fprintf(fe, "%04x\n", eh);
    }

    fclose(fq); fclose(fs); fclose(fe);
    printf("generated bf16 scale pairs + expected\n");
    return 0;
}