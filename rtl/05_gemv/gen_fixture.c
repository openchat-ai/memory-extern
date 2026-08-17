/* gen_fixture.c — 为 RTL 第 5 课（数字外围 MAC）生成测试数据。
 *
 * 设备路径（sim_cim.c:6-9 的语义）：
 *   激活 x ——DAC(本生成器不量化，直接用 fp32) —— 模拟阵列组段部分和
 *   q[r][g] = Σ_{i∈g} E2M1(w)·x[i]   （double 无逐元素舍入 = 模拟累加）
 *   —— ADC(量化到 adc_bits, 按本次调用 max|q| 校准) —— 数字外围:
 *   y[r] = fp32 累加 Σ_g  q_adc[r][g] × 2^(sb-127)
 *
 * 本工具输出三个文件（供 $readmemh）：
 *   q.hex        每行一个 fp32（ADC 量化后的组段部分和）
 *   scale.hex    每行一个 E8M0 尺度字节
 *   expected.hex 每行一个 fp32（数字外围黄金参考 y，由 pim_mxfp4_periph_acc 逐位）
 *
 * 输入：pim/fixture_mxfp4.bin 的 packed/scales/geometry。激活 x 由固定种子
 * LCG 生成（与 verify.c 同一 rng，[-1,1]），保证可复现。
 */
#include "mxfp4_gemv.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static uint32_t rng = 0x12345678u;
static float next_rand(void)
{
    rng = rng * 1664525u + 1013904223u;
    return ((float)(rng >> 8) / 16777216.0f) * 2.0f - 1.0f;
}

/* ADC：按调用级 max|q| 校准全量程，量化到 adc_bits（同 sim_cim dac_quant 形式） */
static double adc_quant(double v, double step, double rmax)
{
    double qv = round(v / step) * step;
    if (qv >  rmax) qv =  rmax;
    if (qv < -rmax) qv = -rmax;
    return qv;
}

static void emit_f32(FILE *fp, float v)
{
    uint32_t u; memcpy(&u, &v, 4);
    fprintf(fp, "%08x\n", u);
}

int main(int argc, char **argv)
{
    const char *src = argc > 1 ? argv[1] : "pim/fixture_mxfp4.bin";
    const int adc_bits = argc > 2 ? atoi(argv[2]) : 12;

    FILE *fp = fopen(src, "rb");
    if (!fp) { perror(src); return 2; }
    int rows, pc, sc, width, group;
    if (fread(&rows, 4, 1, fp) != 1 || fread(&pc, 4, 1, fp) != 1 ||
        fread(&sc, 4, 1, fp) != 1 || fread(&width, 4, 1, fp) != 1 ||
        fread(&group, 4, 1, fp) != 1) return 2;
    size_t np = (size_t)rows * pc, ns = (size_t)rows * sc;
    uint8_t *packed = malloc(np), *scales = malloc(ns);
    if (fread(packed, 1, np, fp) != np || fread(scales, 1, ns, fp) != ns) return 2;
    fclose(fp);

    const int ngrp = width / group;              /* fixture: width 整除 group */
    const int gbyte = group / 2;
    float *x = malloc((size_t)width * 4);
    for (int i = 0; i < width; i++) x[i] = next_rand();

    /* 1. 模拟阵列：组段部分和（double，无逐元素舍入 = 模拟累加的语义） */
    double *qraw = malloc((size_t)rows * ngrp * 8);
    double amax = 0.0;
    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pc;
        for (int g = 0; g < ngrp; g++) {
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            double acc = 0.0;
            for (int j = 0; j < gbyte; j++) {
                double w0 = PIM_E2M1[pb[j] & 0x0F], w1 = PIM_E2M1[pb[j] >> 4];
                acc += w0 * xg[2 * j] + w1 * xg[2 * j + 1];
            }
            qraw[(size_t)r * ngrp + g] = acc;
            if (fabs(acc) > amax) amax = fabs(acc);
        }
    }
    if (amax == 0.0) amax = 1.0;
    const double astep = amax / (double)(1 << (adc_bits - 1));

    /* 2. ADC 量化 → 数字外围黄金参考（单一真相源：pim/mxfp4_gemv.c） */
    float *qarr = malloc((size_t)rows * ngrp * 4);
    for (size_t i = 0; i < (size_t)rows * ngrp; i++)
        qarr[i] = (float)adc_quant(qraw[i], astep, amax);
    float *y = malloc((size_t)rows * 4);
    pim_mxfp4_periph_acc(y, qarr, scales, rows, ngrp);

    FILE *fq = fopen("q.hex", "w");
    FILE *fs = fopen("scale.hex", "w");
    FILE *fe = fopen("expected.hex", "w");
    if (!fq || !fs || !fe) return 3;
    for (int r = 0; r < rows; r++) {
        for (int g = 0; g < ngrp; g++) {
            emit_f32(fq, qarr[(size_t)r * ngrp + g]);
            fprintf(fs, "%02x\n", scales[(size_t)r * sc + g]);
        }
        emit_f32(fe, y[r]);
    }
    fclose(fq); fclose(fs); fclose(fe);
    printf("rows=%d width=%d group=%d ngrp=%d adc_bits=%d  (q+scale=%d, y=%d)\n",
           rows, width, group, ngrp, adc_bits, rows * ngrp, rows);
    free(qraw); free(qarr); free(y); free(x); free(packed); free(scales);
    return 0;
}

