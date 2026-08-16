/* sim_c500.c — C500 硬件行为模拟器：真设备算法，对照 double 精准参考。
 *
 * 按 c500-kernel.md §目标MMA 的规格重建（mma_sim.c 从未入库，需重建）：
 *
 *   MMA: C[16][16] += A[16][16]·B[16][16]，A/B 为 bf16，C 为 fp32。
 *   B fragment 融合去量化：每个 16 宽 k-tile 恰被一个 E8M0 scale 管辖
 *   （ktile 偶数=group 低半，奇数=高半），scale 在加载时乘入权重：
 *       w[i] = bf16(E2M1[nib] · 2^(sb-127))   —— 无损（E2M1 值域 ≤1 尾数位）
 *   A 侧激活 bf16（RNE 舍入）。C 在 ktile 循环内顺序 fp32 累加。
 *
 * 与 CPU 参考（k3_matmul_mxfp4）的三处结构性差异 —— 这就是"模拟污染"的根源：
 *   1. 累加：硬件 = 整条 in 维顺序 fp32（每 MMA k=0..15，跨 ktile 携带 C）；
 *      CPU  = 8 累加器残差分区 + 树状归约 + double。
 *   2. scale 位置：硬件 = 加载时先乘（每 16 宽 tile）；CPU = group 点积后再乘
 *      （每 32 宽 group）。
 *   3. 精度：硬件全程 fp32/bf16，无 double。
 * 精确算术下 1、2 等价；fp32 舍入下完全不同 → 必须按硬件结构模拟，不能拿
 * "CPU 算法 + float 累加"冒充设备路径。
 */
#include "mxfp4_gemv.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- 参考核（double 累加，逐位精准） ---- */
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

/* ---- C500 设备路径：B fragment 加载时乘 scale（每 16 宽 k-tile），bf16 激活，
 * 整条 in 维顺序 fp32 累加。 ---- */
static float bf16_round(float x)
{
    uint32_t u, rounded;
    memcpy(&u, &x, 4);
    rounded = 0x7FFF + ((u >> 16) & 1);          /* round-to-nearest-even at bit 16 */
    u = (u + rounded) & 0xFFFF0000u;
    float y;
    memcpy(&y, &u, 4);
    return y;
}

static void dev_c500_gemv(float *y, const float *x, const unsigned char *packed,
                          const unsigned char *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    if (!REF_READY) ref_init();

    for (int r = 0; r < rows; r++) {
        const unsigned char *pr = packed + (size_t)r * pcols;
        float acc = 0.0f;                        /* C fragment：跨 ktile 顺序 fp32 */
        for (int kt = 0; kt * 16 < in; kt++) {   /* ktile = 16 宽 */
            const int g = kt / 2;                /* 偶数=group 低半，奇数=高半 */
            const unsigned char sb = scales[(size_t)r * ((in + group - 1) / group) + g];
            const float mult = (sb == 255) ? 0.0f : ldexpf(1.0f, (int)sb - 127);
            for (int k = 0; k < 16; k++) {
                const int i = kt * 16 + k;
                if (i >= in) break;
                /* B fragment 加载：w = bf16(E2M1[nib]·mult)，无损 */
                const unsigned char byte = pr[i >> 1];
                const unsigned char nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                const float w = REF_E2M1[nib] * mult;
                /* A fragment：bf16 激活；MMA 内 fp32 FMA */
                acc = fmaf(w, bf16_round(x[i]), acc);
            }
        }
        y[r] = acc;
    }
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

    float *x = malloc((size_t)width * 4);
    float *refy = malloc((size_t)rows * 4);
    float *d16 = malloc((size_t)rows * 4);

    double maxrel_bf16 = 0, p999_bf16 = 0, nrms_bf16 = 0;

    const int SEEDS = 3;                       /* 3 个固定种子，取最差 */
    for (int s = 0; s < SEEDS; s++) {
        rng = 0x1000 + s;
        for (int i = 0; i < width; i++) x[i] = next_rand() * 1.5f;  /* ~N(0,1) 风格 */
        ref_k3_matmul_mxfp4(refy, x, packed, scales, width, rows, group);
        dev_c500_gemv(d16, x, packed, scales, width, rows, group);
        Stats b;
        stats(d16, refy, rows, &b);
        if (b.maxrel > maxrel_bf16) { maxrel_bf16 = b.maxrel; p999_bf16 = b.p999; }
        if (b.normrms > nrms_bf16) nrms_bf16 = b.normrms;
    }

    printf("\nC500 硬件路径精度（忠实行为模拟，真实 checkpoint 字节，最差 over 3 种子）:\n");
    printf("  scale@load + bf16激活 + fp32顺序累加:\n");
    printf("    maxrel=%.3e  p99.9=%.3e  max|err|/RMS=%+.2e\n",
           maxrel_bf16, p999_bf16, nrms_bf16);
    printf("\n旧的污染模拟（CPU 算法+float）当时给出: maxrel=1.4e-1 p99.9=2.0e-2 "
           "max|err|/RMS=4.1e-3 —— 结构不同数字不同，见证污染\n");
    printf("c500-kernel.md 声称: bf16激活 1.82e-3（mma_sim.c 未入库，无法复现，待重建核对）\n");

    printf("\n解读:\n");
    printf("  1. 硬件路径的误差 = 顺序 fp32 累加 + bf16 激活舍入，信号归一口径 ~1e-3 量级\n");
    printf("  2. maxrel 仍被近零点积放大（分母→0），看 p99.9 / max|err|/RMS\n");
    printf("  3. 全为算法层预算：设备真按此算术执行才成立（需硬件/cycle 仿真证）\n");
    printf("  4. 与 CPU 参考不同步：硬件不逐位对齐 CPU，契约 = 误差落在容忍内\n");
    return 0;
}
