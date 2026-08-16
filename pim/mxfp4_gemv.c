/* pim_mxfp4_gemv.c — the PIM-side expert matmul, standalone.
 *
 * The ONLY computation a memory device performs in this design (see README §1).
 * No engine headers; the E2M1/E8M0 tables and the summation order are reproduced
 * here so the module is self-contained and bit-exact against the production
 * reference k3_matmul_mxfp4 (kimi-k3 fork, src/core/k3_ops.c:1243).
 */
#include "mxfp4_gemv.h"

#include <math.h>

/* Pair table: byte -> {low-nibble value, high-nibble value}. Low nibble = EVEN
 * element; reversing it produces right statistics in wrong positions. Built the
 * same way as k3_pair_init (k3_ops.c:1191). */
static float PIM_E2M1_PAIR[256][2];

/* E8M0: bare biased exponent -> power of two. 255 is NaN by spec; map to zero so
 * one bad byte cannot poison a row. Same rule as k3_e8m0_init (k3_ops.c:1206). */
static float PIM_E8M0[256];

static int PIM_READY = 0;

static void pim_tables_init(void)
{
    for (int b = 0; b < 256; b++) {
        PIM_E2M1_PAIR[b][0] = PIM_E2M1[b & 0x0F];
        PIM_E2M1_PAIR[b][1] = PIM_E2M1[b >> 4];
    }
    for (int b = 0; b < 256; b++)
        PIM_E8M0[b] = (b == 255) ? 0.0f : ldexpf(1.0f, b - 127);
    PIM_READY = 1;
}

void pim_mxfp4_gemv(float *y, const float *x, const uint8_t *packed,
                    const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;

    if (!PIM_READY) pim_tables_init();

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        double acc = 0.0;

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;               /* NaN scale: contribute nothing */
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;

            int n = in - g * group;
            if (n > group) n = group;

            /* Expand the group to floats first, then dot. The reference splits this
             * out so the accumulation loop can vectorise without a table lookup in
             * the middle of it. */
            float wf[64];
            const int half = n >> 1;
            for (int j = 0; j < half; j++) {
                const float *pv = PIM_E2M1_PAIR[pb[j]];
                wf[2 * j]     = pv[0];
                wf[2 * j + 1] = pv[1];
            }
            if (n & 1) wf[n - 1] = PIM_E2M1_PAIR[pb[half]][0];

            /* Eight double accumulators partitioned by (i+8*l)%8, reduced as
             * ((s0+s4)+(s1+s5)) + ((s2+s6)+(s3+s7)) — the scalar reference's exact
             * partition and tree (k3_ops.c:1276). fma() is the same IEEE op as the
             * reference's scalar path with -ffp-contract=off. */
            double s[8] = {0};
            int i = 0;
            for (; i + 7 < n; i += 8)
                for (int l = 0; l < 8; l++)
                    s[l] = fma((double)wf[i + l], (double)xg[i + l], s[l]);
            double b0 = s[0] + s[4], b1 = s[1] + s[5];
            double b2 = s[2] + s[6], b3 = s[3] + s[7];
            double sub = (b0 + b1) + (b2 + b3);
            for (; i < n; i++) sub = fma((double)wf[i], (double)xg[i], sub);
            acc += sub * (double)PIM_E8M0[sb];     /* scale ONCE per group, after the dot */
        }
        y[r] = (float)acc;
    }
}

void pim_mxfp4_dequant(float *out, const uint8_t *packed, const uint8_t *scales,
                       int rows, int pcols, int group)
{
    const int width = pcols * 2;
    const int ngrp  = (width + group - 1) / group;

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float *orow = out + (size_t)r * width;

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            const float mult = (sb == 255) ? 0.0f : ldexpf(1.0f, (int)sb - 127);

            const int lo = g * group;
            int hi = lo + group;
            if (hi > width) hi = width;

            for (int i = lo; i < hi; i++) {
                const uint8_t byte = pr[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                orow[i] = PIM_E2M1[nib] * mult;
            }
        }
    }
}
