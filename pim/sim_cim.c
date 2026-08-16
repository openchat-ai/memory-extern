/* sim_cim.c — 内存计算单元（CIM crossbar）行为模拟器，对照 double 精准参考。
 *
 * 参照物 = 内存计算单元，不是任何张量核（C500 已作为污染源删除，不再引用）。
 *
 * 设备结构（本规格的定义）：
 *
 *   激活 x ──► DAC（量化，DAC_BITS）──► 模拟阵列（组段逐组累加 Σ E2M1·x，
 *   模拟累加无逐元素舍入）──► ADC（量化组段部分和，ADC_BITS）
 *   ──► 数字外围：乘 E8M0 scale（2^(sb-127)）──► fp32 跨组累加 ──► y[out]
 *
 * 关键结构性决策（与 CPU 参考的根本差异）：
 *   1. 累加发生在模拟域：组段内无舍入（电荷/电流相加），不是 fp32/double。
 *   2. E8M0 scale 在数字外围、ADC 之后应用（组段部分和 ×2^(sb-127)）。
 *      原因：scale 是 per-row 的，而激活是跨 row 共享的，物理上不能把
 *      per-row 的 scale 折进共享的 DAC 输入；折进电导又要求电导动态范围
 *      覆盖 2^0..2^127，不物理。→ scale 应用留在契约允许的数字侧。
 *   3. 权重 = E2M1 值集 {0, ±0.5, ±1, ±1.5, ±2, ±3, ±4, ±6} = 15 非零 + 0
 *      = 16 电平，恰好一个 4-bit 模拟 cell 无损存储（与 CPU 参考同源）。
 *   4. 跨组累加在数字侧 fp32（vs 参考 double）—— 结构差异只有 ~1e-7 量级。
 *
 * 误差来源（三层全为量化，无浮点累加结构差异）：
 *   1. DAC：激活 x 量化到 DAC_BITS（按本次调用 max|x| 校准）。
 *   2. ADC：组段模拟部分和量化到 ADC_BITS（按本次调用 max|s| 校准）。
 *   3. 数字外围：scale 乘 + 跨组 fp32 累加 vs 参考 double。
 * 注意：真实器件噪声（cell 变异、IR drop、热噪声）未建模 —— 这是理想无噪声
 * 下界；器件裕量必须落在它之上。此点必须在规格里显式声明，防止把理想模拟
 * 数字误当器件实测。
 */
#include "mxfp4_gemv.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { int dac; int adc; } Cfg;

static float next_rand(void);   /* 定义在下方（fixture 之后） */

/* ---- 参考核（CPU 参考：double 累加，逐位精准） ---- */
static float REF_E2M1[16] = {
    0.0f, 0.5f, 1.0f, 1.5f, 2.0f, 3.0f, 4.0f, 6.0f,
    -0.0f, -0.5f, -1.0f, -1.5f, -2.0f, -3.0f, -4.0f, -6.0f
};
static float REF_E2M1_PAIR[256][2];
static float REF_E8M0[256];
static int REF_READY = 0;

static void ref_init(void)
{
    for (int b = 0; b < 256; b++) {
        REF_E2M1_PAIR[b][0] = REF_E2M1[b & 0x0F];
        REF_E2M1_PAIR[b][1] = REF_E2M1[b >> 4];
    }
    for (int b = 0; b < 256; b++)
        REF_E8M0[b] = (b == 255) ? 0.0f : ldexpf(1.0f, b - 127);
    REF_READY = 1;
}

static void ref_k3_matmul_mxfp4(float *y, const float *x, const unsigned char *packed,
                                const unsigned char *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;
    if (!REF_READY) ref_init();

    for (int r = 0; r < rows; r++) {
        const unsigned char *pr = packed + (size_t)r * pcols;
        const unsigned char *sr = scales + (size_t)r * ngrp;
        double acc = 0.0;
        for (int g = 0; g < ngrp; g++) {
            const unsigned char sb = sr[g];
            if (sb == 255) continue;
            const unsigned char *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;
            float wf[64];
            const int half = n >> 1;
            for (int j = 0; j < half; j++) {
                const float *pv = REF_E2M1_PAIR[pb[j]];
                wf[2 * j]     = pv[0];
                wf[2 * j + 1] = pv[1];
            }
            if (n & 1) wf[n - 1] = REF_E2M1_PAIR[pb[half]][0];
            double s[8] = {0};
            int i = 0;
            for (; i + 7 < n; i += 8)
                for (int l = 0; l < 8; l++)
                    s[l] = fma((double)wf[i + l], (double)xg[i + l], s[l]);
            double b0 = s[0] + s[4], b1 = s[1] + s[5];
            double b2 = s[2] + s[6], b3 = s[3] + s[7];
            double sub = (b0 + b1) + (b2 + b3);
            for (; i < n; i++) sub = fma((double)wf[i], (double)xg[i], sub);
            acc += sub * (double)REF_E8M0[sb];
        }
        y[r] = (float)acc;
    }
}

/* ---- 器件噪声模型（流片规格必需：理想模拟只是下界，真实器件只会更差） ----
 *   cell_var : 电导存储误差，乘性，相对标准差 σ（每个权重单元独立采样）
 *   noise_fs : 列/热噪声，加性，标准差 = noise_fs × ADC 全量程 amax（每个组段独立）
 *   ir_drop  : 行位置相关增益误差，乘性，1 + ir_drop·(r/mid - 1)（IR drop 渐变）
 */
typedef struct {
    const char *name;
    double cell_var;
    double noise_fs;
    double ir_drop;
} Noise;

static const Noise NOISE[] = {
    { "理想（无器件噪声）",            0.0,    0.0,   0.0 },
    { "cell变异 0.5%",                 0.005,  0.0,   0.0 },
    { "cell变异 1%",                   0.01,   0.0,   0.0 },
    { "cell变异 1% + 列噪声0.1%FS",    0.01,   0.001, 0.0 },
    { "cell变异 2% + 列噪声0.1%FS",    0.02,   0.001, 0.0 },
    { "cell变异 2% + 列噪声0.3%FS",    0.02,   0.003, 0.0 },
};

/* Box-Muller 高斯（复用 rng，每 seed 重置，可复现）
 *   u1 ∈ (0,1]，u2 ∈ (0,1)；r = sqrt(-2 ln u1)，z = r·sin(2π·u2) */
static double next_gauss(void)
{
    double u1 = ((double)next_rand() + 1.0) * 0.5;   /* [-1,1] → [0,1) */
    double u2 = ((double)next_rand() + 1.0) * 0.5;
    if (u1 <= 0.0) u1 = 1e-9;
    if (u2 <= 0.0) u2 = 1e-9;
    return sqrt(-2.0 * log(u1)) * sin(6.283185307179586 * u2);
}

/* ---- 内存计算单元路径：DAC → 模拟组段累加 → ADC → 数字 scale → fp32 跨组累加 ---- */
static double dac_quant(double v, double step, double rmax)
{
    double q = round(v / step) * step;
    if (q >  rmax) q =  rmax;
    if (q < -rmax) q = -rmax;
    return q;
}

static void dev_cim_gemv(float *y, const float *x, const unsigned char *packed,
                         const unsigned char *scales, int in, int rows, int group,
                         int dac_bits, int adc_bits, const Noise *nz)
{
    const int ngrp = (in + group - 1) / group;
    const int pcols = in / 2;
    if (!REF_READY) ref_init();

    /* 1. DAC：按本次调用 max|x| 校准全量程，量化整条激活向量 */
    double rmax = 0.0;
    for (int i = 0; i < in; i++) {
        double a = fabs((double)x[i]);
        if (a > rmax) rmax = a;
    }
    if (rmax == 0.0) rmax = 1.0;
    const double dac_step = rmax / (double)(1 << (dac_bits - 1));

    /* 2. 模拟阵列：组段部分和（double 无逐元素舍入，模拟"电荷/电流相加"）。
     *    同时求全调用 max|s|，作为 ADC 全量程（校准）。
     */
    double *s = malloc((size_t)rows * ngrp * sizeof(double));
    double amax = 0.0;
    for (int r = 0; r < rows; r++) {
        const unsigned char *pr = packed + (size_t)r * pcols;
        /* IR drop：行位置相关增益（行靠 bitline 驱动端近端无 drop，远端最大） */
        const double ir = 1.0 + nz->ir_drop * ((double)r / (rows > 1 ? rows - 1 : 1) - 0.5);
        for (int g = 0; g < ngrp; g++) {
            int n = in - g * group;
            if (n > group) n = group;
            const int half = n >> 1;
            const unsigned char *pb = pr + (size_t)g * (group / 2);
            const int base = g * group;
            double acc = 0.0;
            for (int j = 0; j < half; j++) {
                const float *pv = REF_E2M1_PAIR[pb[j]];
                /* cell 变异：电导存储误差，乘性，逐权重独立 */
                double w0 = pv[0] * (1.0 + nz->cell_var * next_gauss());
                double w1 = pv[1] * (1.0 + nz->cell_var * next_gauss());
                double x0 = dac_quant((double)x[base + 2 * j],     dac_step, rmax);
                double x1 = dac_quant((double)x[base + 2 * j + 1], dac_step, rmax);
                acc += ir * (w0 * x0 + w1 * x1);
            }
            if (n & 1) {
                double w = (double)REF_E2M1[pb[half] & 0x0F] * (1.0 + nz->cell_var * next_gauss());
                double xq = dac_quant((double)x[base + n - 1], dac_step, rmax);
                acc += ir * w * xq;
            }
            s[(size_t)r * ngrp + g] = acc;
            double a = fabs(acc);
            if (a > amax) amax = a;
        }
    }
    if (amax == 0.0) amax = 1.0;
    const double adc_step = amax / (double)(1 << (adc_bits - 1));
    const double th_noise = nz->noise_fs * amax;

    /* 3. ADC + 数字外围：量化组段部分和（+列/热噪声）→ ×scale → fp32 跨组累加 */
    for (int r = 0; r < rows; r++) {
        const unsigned char *sr = scales + (size_t)r * ngrp;
        float acc = 0.0f;
        for (int g = 0; g < ngrp; g++) {
            const unsigned char sb = sr[g];
            if (sb == 255) continue;
            double q = dac_quant(s[(size_t)r * ngrp + g] + th_noise * next_gauss(),
                                 adc_step, amax);
            float w = (float)q * (float)REF_E8M0[sb];   /* fp32 尺度应用 */
            acc += w;                                    /* fp32 跨组累加 */
        }
        y[r] = acc;
    }
    free(s);
}

/* ---- fixture ---- */
static int load_fixture(const char *path, int *rows, int *pcols, int *width, int *group,
                        uint8_t **packed, uint8_t **scales)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) return -1;
    int scols;
    if (fread(rows, 4, 1, fp) != 1 || fread(pcols, 4, 1, fp) != 1 ||
        fread(&scols, 4, 1, fp) != 1 || fread(width, 4, 1, fp) != 1 ||
        fread(group, 4, 1, fp) != 1) { fclose(fp); return -1; }
    size_t np = (size_t)*rows * *pcols, ns = (size_t)*rows * scols;
    *packed = malloc(np); *scales = malloc(ns);
    if (!*packed || !*scales) { fclose(fp); return -1; }
    if (fread(*packed, 1, np, fp) != np || fread(*scales, 1, ns, fp) != ns) {
        fclose(fp); return -1;
    }
    fclose(fp);
    return 0;
}

static uint32_t rng = 1;
static float next_rand(void)
{
    rng = rng * 1664525u + 1013904223u;
    return ((float)(rng >> 8) / 16777216.0f) * 2.0f - 1.0f;
}

/* 相对误差统计：|dev-ref|/|ref|，ref==0 时按绝对差 / (1+max|ref|) 计 */
typedef struct { double maxrel; double p999; double normrms; } Stats;

static int cmp_d(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/* normrms = max |dev-ref| / RMS(ref) —— 绝对误差对信号尺度的比值，不受近零点积
 * 的相对放大影响，是下游精度的真实口径。 */
static void stats(const float *dev, const float *ref, int n, Stats *st)
{
    static double rels[4096];
    int m = 0;
    double maxabs = 1.0, sumsq = 0;
    for (int i = 0; i < n; i++) {
        if (fabs((double)ref[i]) > maxabs) maxabs = fabs((double)ref[i]);
        sumsq += (double)ref[i] * (double)ref[i];
    }
    double rms = sqrt(sumsq / n);
    double normmax = 0;
    for (int i = 0; i < n; i++) {
        double r = fabs((double)ref[i]);
        double d = fabs((double)dev[i] - (double)ref[i]);
        rels[m++] = (r > 0) ? d / r : d / maxabs;
        double nn = d / rms;
        if (nn > normmax) normmax = nn;
    }
    qsort(rels, m, sizeof(double), cmp_d);
    st->maxrel = rels[m - 1];
    st->p999 = rels[(int)((m - 1) * 0.999)];
    st->normrms = normmax;
}

int main(void)
{
    int rows, pcols, width, group;
    uint8_t *packed, *scales;
    if (load_fixture("fixture_mxfp4.bin", &rows, &pcols, &width, &group,
                     &packed, &scales)) {
        fprintf(stderr, "cannot load fixture (run: make fixture)\n");
        return 2;
    }
    printf("fixture: rows=%d width=%d group=%d  （对照：double 累加精准参考）\n",
           rows, width, group);
    printf("内存计算单元: DAC/ADC 位数扫描；模拟累加=理想无噪声\n\n");

    float *x = malloc((size_t)width * 4);
    float *refy = malloc((size_t)rows * 4);
    float *d16 = malloc((size_t)rows * 4);

    static const Cfg cfgs[] = {
        { 6, 8 }, { 6, 10 }, { 8, 8 }, { 8, 10 },
        { 8, 12 }, { 10, 10 }, { 10, 12 }, { 12, 12 },
    };

    for (size_t n = 0; n < sizeof(NOISE) / sizeof(NOISE[0]); n++) {
        printf("\n=== 器件噪声场景: %s ===\n", NOISE[n].name);
        printf("  DAC   ADC   maxrel   p99.9   max|err|/RMS\n");
        for (size_t c = 0; c < sizeof(cfgs) / sizeof(cfgs[0]); c++) {
            double maxrel = 0, p999 = 0, nrms = 0;
            const int SEEDS = 3;
            for (int s = 0; s < SEEDS; s++) {
                rng = 0x1000 + s;
                for (int i = 0; i < width; i++) x[i] = next_rand() * 1.5f;
                ref_k3_matmul_mxfp4(refy, x, packed, scales, width, rows, group);
                dev_cim_gemv(d16, x, packed, scales, width, rows, group,
                             cfgs[c].dac, cfgs[c].adc, &NOISE[n]);
                Stats b;
                stats(d16, refy, rows, &b);
                if (b.maxrel > maxrel) { maxrel = b.maxrel; p999 = b.p999; }
                if (b.normrms > nrms) nrms = b.normrms;
            }
            printf("  %2d    %2d   %.3e  %.3e  %+.2e\n",
                   cfgs[c].dac, cfgs[c].adc, maxrel, p999, nrms);
        }
    }

    printf("\n解读:\n");
    printf("  1. 误差 = DAC激活量化 + ADC组段量化 + 器件噪声 + 数字侧scale/fp32累加\n");
    printf("  2. maxrel 仍被近零点积放大（分母→0），看 p99.9 / max|err|/RMS\n");
    printf("  3. 理想场景是无噪声下界；器件噪声（cell变异/热噪声/IR drop）只会更差\n");
    printf("  4. 流片规格:选 DAC/ADC 位数必须给器件噪声留裕量,契约=max|err|/RMS 量级\n");
    printf("  5. 与 CPU 参考不同步：设备不逐位对齐 CPU，契约 = 误差落在容忍内\n");
    return 0;
}
