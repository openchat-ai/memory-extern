/* verify.c — 逐位验证 PIM 参考内核。
 *
 * 三项检查（见 README §5），全部对照真实 checkpoint 字节（fixture_mxfp4.bin）：
 *   1. dequant：pim_mxfp4_dequant == fixture 的 expected（参考去量化，逐位）
 *   2. GEMV：pim_mxfp4_gemv == 生产参考 k3_matmul_mxfp4 的逐字算术（逐位）
 *   3. nibble 对抗：交换低高 nibble 后 pim 与 ref 仍逐位一致，且结果必须变化
 *
 * ref_k3_matmul_mxfp4 是 kimi-k3 fork src/core/k3_ops.c:1243 的逐字复制（仅标量
 * 路径），用于把"PIM 内核是否忠实还原参考求和顺序"变成机器可判的断言。
 */
#include "mxfp4_gemv.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures = 0;

static void fail(const char *what)
{
    fprintf(stderr, "FAIL: %s\n", what);
    failures++;
}

/* ---- 参考核：k3_ops.c:1243 逐字保留（标量路径） ---- */
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

/* ---- 工具 ---- */
static int bits_equal(const float *a, const float *b, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        uint32_t ua, ub;
        memcpy(&ua, &a[i], 4);
        memcpy(&ub, &b[i], 4);
        if (ua != ub) return 0;
    }
    return 1;
}

static uint32_t rng = 0x12345678u;
static float next_rand(void)
{
    rng = rng * 1664525u + 1013904223u;
    return ((float)(rng >> 8) / 16777216.0f) * 2.0f - 1.0f;   /* [-1, 1] */
}

static void make_activation(const char *kind, float *x, int n)
{
    rng = 0x12345678u;
    for (int i = 0; i < n; i++) {
        if (!strcmp(kind, "zeros")) {
            x[i] = 0.0f;
        } else if (!strcmp(kind, "ones")) {
            x[i] = 1.0f;
        } else if (!strcmp(kind, "alt")) {
            x[i] = (i & 1) ? -1.0f : 1.0f;
        } else if (!strcmp(kind, "rand")) {
            x[i] = next_rand();
        } else if (!strcmp(kind, "small")) {          /* ~N(0,1) 风格，接近真实激活 */
            x[i] = next_rand() * 1.5f;
        } else if (!strcmp(kind, "special")) {        /* 覆盖 ±0/inf/nan/极值 */
            const float spec[8] = {
                0.0f, -0.0f, INFINITY, -INFINITY, NAN,
                FLT_MAX, FLT_TRUE_MIN, 1e-30f
            };
            x[i] = spec[i % 8];
        }
    }
}

/* ---- fixture ---- */
typedef struct {
    int rows, pcols, scols, width, group;
    uint8_t *packed;
    uint8_t *scales;
    float *expected;
} Fixture;

static int load_fixture(const char *path, Fixture *f)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); return -1; }
    if (fread(&f->rows, 4, 1, fp) != 1 ||
        fread(&f->pcols, 4, 1, fp) != 1 ||
        fread(&f->scols, 4, 1, fp) != 1 ||
        fread(&f->width, 4, 1, fp) != 1 ||
        fread(&f->group, 4, 1, fp) != 1) { fclose(fp); return -1; }
    size_t np = (size_t)f->rows * f->pcols;
    size_t ns = (size_t)f->rows * f->scols;
    size_t ne = (size_t)f->rows * f->width;
    f->packed = malloc(np);
    f->scales = malloc(ns);
    f->expected = malloc(ne * 4);
    if (!f->packed || !f->scales || !f->expected) { fclose(fp); return -1; }
    if (fread(f->packed, 1, np, fp) != np ||
        fread(f->scales, 1, ns, fp) != ns ||
        fread(f->expected, 4, ne, fp) != ne) { fclose(fp); return -1; }
    fclose(fp);
    return 0;
}

int main(void)
{
    const char *path = "fixture_mxfp4.bin";
    Fixture f;
    if (load_fixture(path, &f)) {
        fprintf(stderr, "cannot load %s (run: make fixture)\n", path);
        return 2;
    }
    printf("fixture: rows=%d packed_cols=%d scale_cols=%d width=%d group=%d\n",
           f.rows, f.pcols, f.scols, f.width, f.group);

    /* 1. dequant 逐位 vs expected */
    float *deq = malloc((size_t)f.rows * f.width * 4);
    pim_mxfp4_dequant(deq, f.packed, f.scales, f.rows, f.pcols, f.group);
    if (bits_equal(deq, f.expected, (size_t)f.rows * f.width))
        printf("PASS dequant: pim_mxfp4_dequant == fixture expected (bit-exact)\n");
    else
        fail("dequant not bit-exact vs fixture expected");

    /* 2. GEMV 逐位 vs 参考核，多组激活 */
    const char *kinds[] = {"zeros", "ones", "alt", "rand", "small", "special"};
    const int nkinds = sizeof(kinds) / sizeof(kinds[0]);
    float *x = malloc((size_t)f.width * 4);
    float *refy = malloc((size_t)f.rows * 4);
    float *pimy = malloc((size_t)f.rows * 4);

    for (int k = 0; k < nkinds; k++) {
        make_activation(kinds[k], x, f.width);
        ref_k3_matmul_mxfp4(refy, x, f.packed, f.scales, f.width, f.rows, f.group);
        pim_mxfp4_gemv(pimy, x, f.packed, f.scales, f.width, f.rows, f.group);
        if (bits_equal(pimy, refy, f.rows))
            printf("PASS gemv[%-8s]: pim == k3 reference (bit-exact)\n", kinds[k]);
        else
            fail("gemv not bit-exact vs reference");
    }

    /* 3. nibble 对抗：交换低高 nibble，必须改变结果，且 pim/ref 仍一致 */
    uint8_t *swp = malloc((size_t)f.rows * f.pcols);
    for (size_t i = 0; i < (size_t)f.rows * f.pcols; i++)
        swp[i] = (uint8_t)((f.packed[i] >> 4) | ((f.packed[i] & 0x0F) << 4));
    make_activation("rand", x, f.width);
    ref_k3_matmul_mxfp4(refy, x, swp, f.scales, f.width, f.rows, f.group);
    pim_mxfp4_gemv(pimy, x, swp, f.scales, f.width, f.rows, f.group);
    float *orig = malloc((size_t)f.rows * 4);
    pim_mxfp4_gemv(orig, x, f.packed, f.scales, f.width, f.rows, f.group);
    if (!bits_equal(pimy, refy, f.rows)) {
        fail("nibble-swapped pim/ref disagree");
    } else if (bits_equal(pimy, orig, f.rows)) {
        fail("nibble swap changed nothing (nibble order not load-bearing?)");
    } else {
        printf("PASS nibble-swap: pim==ref, result differs from unswapped "
               "(order is load-bearing)\n");
    }
    free(orig);
    free(swp);

    printf(failures ? "\nVERIFY FAILED (%d)\n" : "\nVERIFY ALL PASS\n", failures);
    return failures ? 1 : 0;
}
