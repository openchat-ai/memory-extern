/* gen_e2e.c — 端到端链条数据生成器：真实 checkpoint 权重 → 整条设备路径。
 *
 * 把 04→05 焊成"一台能真算的机器"：
 *   (1) 04 去量化：pim_mxfp4_dequant 逐位 vs fixture 的 expected（C golden）
 *       ——04 课 dequant.v RTL 已对同一 golden 逐位验证，此处做链条根校验
 *   (2) sim_cim 设备路径：DAC(量化激活) → 模拟阵列组段累加(double 无舍入)
 *       → ADC(12bit, 按 max 校准) → q[r][g]（fp32）
 *   (3) 05 数字外围：q.hex/scale.hex 喂 RTL periph_mac，逐位对设备 golden
 *       pim_mxfp4_periph_acc（expected.hex）
 *   (4) 软件参考对拍：同一 x 跑 CPU double 参考 pim_mxfp4_gemv
 *       （expected_cpu.hex）——设备（fp32 外围）不逐位等于 CPU（double），
 *       契约 = 误差容限，输出统计与 sim_cim 同口径。
 *
 * 输出（$readmemh）：
 *   q.hex            每行 fp32：ADC 量化后的组段部分和
 *   scale.hex        每行 E8M0 尺度字节
 *   expected.hex     设备 golden（RTL 逐位目标）
 *   expected_cpu.hex CPU double 参考（对拍目标）
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

static double dac_quant(double v, double step, double rmax)
{
    double q = round(v / step) * step;
    if (q >  rmax) q =  rmax;
    if (q < -rmax) q = -rmax;
    return q;
}

static void emit_f32(FILE *fp, float v)
{
    uint32_t u; memcpy(&u, &v, 4);
    fprintf(fp, "%08x\n", u);
}

int main(int argc, char **argv)
{
    const char *src = argc > 1 ? argv[1] : "../../pim/fixture_mxfp4.bin";
    const int dac_bits = argc > 2 ? atoi(argv[2]) : 8;
    const int adc_bits = argc > 3 ? atoi(argv[3]) : 12;

    FILE *fp = fopen(src, "rb");
    if (!fp) { perror(src); return 2; }
    int rows, pc, sc, width, group;
    if (fread(&rows, 4, 1, fp) != 1 || fread(&pc, 4, 1, fp) != 1 ||
        fread(&sc, 4, 1, fp) != 1 || fread(&width, 4, 1, fp) != 1 ||
        fread(&group, 4, 1, fp) != 1) return 2;
    size_t np = (size_t)rows * pc, ns = (size_t)rows * sc, ne = (size_t)rows * width;
    uint8_t *packed = malloc(np), *scales = malloc(ns);
    float *expected = malloc(ne * 4);
    if (fread(packed, 1, np, fp) != np || fread(scales, 1, ns, fp) != ns ||
        fread(expected, 4, ne, fp) != ne) return 2;
    fclose(fp);

    printf("fixture: rows=%d width=%d group=%d\n", rows, width, group);
    const int ngrp = width / group;
    const int gbyte = group / 2;

    /* (1) 04 去量化 vs fixture expected（链条根：权重字节 → fp32） */
    float *deq = malloc(ne * 4);
    pim_mxfp4_dequant(deq, packed, scales, rows, pc, group);
    int deq_bad = 0;
    for (size_t i = 0; i < ne; i++) {
        uint32_t a, b; memcpy(&a, &deq[i], 4); memcpy(&b, &expected[i], 4);
        if (a != b) deq_bad++;
    }
    printf("[04 dequant] pim_mxfp4_dequant vs fixture expected: %s (%zu 元素)\n",
           deq_bad ? "FAIL" : "bit-exact", ne);

    /* 激活：真实激活尺度 ~N(0,1)（verify.c 的 small 同款） */
    float *x = malloc((size_t)width * 4);
    for (int i = 0; i < width; i++) x[i] = next_rand() * 1.5f;

    /* (2) sim_cim 设备路径：DAC → 模拟阵列 → ADC */
    double rmax = 0.0;
    for (int i = 0; i < width; i++)
        if (fabs((double)x[i]) > rmax) rmax = fabs((double)x[i]);
    if (rmax == 0.0) rmax = 1.0;
    const double dac_step = rmax / (double)(1 << (dac_bits - 1));

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
                double x0 = dac_quant((double)xg[2 * j],     dac_step, rmax);
                double x1 = dac_quant((double)xg[2 * j + 1], dac_step, rmax);
                acc += w0 * x0 + w1 * x1;          /* 模拟累加：double 无逐元素舍入 */
            }
            qraw[(size_t)r * ngrp + g] = acc;
            if (fabs(acc) > amax) amax = fabs(acc);
        }
    }
    if (amax == 0.0) amax = 1.0;
    const double astep = amax / (double)(1 << (adc_bits - 1));

    float *qarr = malloc((size_t)rows * ngrp * 4);
    for (size_t i = 0; i < (size_t)rows * ngrp; i++) {
        double qv = round(qraw[i] / astep) * astep;
        if (qv >  amax) qv =  amax;
        if (qv < -amax) qv = -amax;
        qarr[i] = (float)qv;
    }

    /* (3) 设备 golden + (4) CPU double 参考 */
    float *ydev = malloc((size_t)rows * 4);
    float *ycpu = malloc((size_t)rows * 4);
    pim_mxfp4_periph_acc(ydev, qarr, scales, rows, ngrp);
    pim_mxfp4_gemv(ycpu, x, packed, scales, width, rows, group);

    FILE *fq = fopen("q.hex", "w");
    FILE *fs = fopen("scale.hex", "w");
    FILE *fe = fopen("expected.hex", "w");
    FILE *fc = fopen("expected_cpu.hex", "w");
    if (!fq || !fs || !fe || !fc) return 3;
    for (int r = 0; r < rows; r++) {
        for (int g = 0; g < ngrp; g++) {
            emit_f32(fq, qarr[(size_t)r * ngrp + g]);
            fprintf(fs, "%02x\n", scales[(size_t)r * sc + g]);
        }
        emit_f32(fe, ydev[r]);
        emit_f32(fc, ycpu[r]);
    }
    fclose(fq); fclose(fs); fclose(fe); fclose(fc);
    printf("wrote q/scale/expected/expected_cpu: rows=%d ngrp=%d dac=%d adc=%d\n",
           rows, ngrp, dac_bits, adc_bits);
    free(packed); free(scales); free(expected); free(deq); free(x);
    free(qraw); free(qarr); free(ydev); free(ycpu);
    return deq_bad ? 1 : 0;
}