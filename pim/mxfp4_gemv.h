#ifndef PIM_MXFP4_GEMV_H
#define PIM_MXFP4_GEMV_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* OCP MX E2M1: index by the 4-bit code; bit 3 is the sign. */
static const float PIM_E2M1[16] = {
    0.0f,  0.5f,  1.0f,  1.5f,  2.0f,  3.0f,  4.0f,  6.0f,
   -0.0f, -0.5f, -1.0f, -1.5f, -2.0f, -3.0f, -4.0f, -6.0f
};

/* y[out] = W[out][in] . x[in], where W is stored MXFP4-packed.
 *
 * This is the ONE computation the PIM device performs; everything else in a MoE
 * forward lives on the host (see pim/README.md §1). It is written to reproduce the
 * production reference k3_matmul_mxfp4 (k3_ops.c:1243) bit for bit:
 *
 *   - per 32-element group: expand nibbles to fp32, dot in a partition fixed by
 *     the reference (8 double accumulators split by (i+4*l)%8, reduced as
 *     (b0+b1)+(b2+b3), tail as fma), then multiply the group's sub-total by its
 *     E8M0 scale once;
 *   - the scale multiply happens AFTER the group dot, not per element;
 *   - a single double accumulator across groups;
 *   - sb == 255 (NaN scale) contributes nothing.
 *
 * Changing any of these breaks bit-exactness against the reference, which verify.c
 * asserts on real checkpoint bytes.
 */
void pim_mxfp4_gemv(float *y, const float *x,
                    const uint8_t *packed, const uint8_t *scales,
                    int in, int rows, int group);

/* Dequantise rows of MXFP4 to fp32. out[rows][pcols*2]. Exists for cross-checking
 * against the fixture's expected dequantisation; the PIM path never materialises W. */
void pim_mxfp4_dequant(float *out,
                       const uint8_t *packed, const uint8_t *scales,
                       int rows, int pcols, int group);

#ifdef __cplusplus
}
#endif

#endif /* PIM_MXFP4_GEMV_H */
