/* bench_gemv.c — 引擎性能基准 v2：消除旧版测量伪影。
 *
 * 旧版问题：
 *   - 每 rep 修改 x[] → 多线程共享 x 引入 false sharing
 *   - pk/sc 在 heap 驻留 → DRAM 场景权重实际命中 L3
 *   - 无 warmup → 首次 cold-cache 与后续 hot 混在一起
 *
 * 本版设计：
 *   1) bench_kernel(fn, rows, cols, reps)  —— 纯计算基准（x/pk/sc 全部热）
 *   2) bench_mt(fn, nthreads, rows, cols, reps) —— 多线程，每线程独立 x 拷贝
 *   3) bench_dram(fn, rows, cols, reps)    —— DRAM 瓶颈基准（pk > L3，rep 间 flush）
 *
 * 用法: ./bench_gemv [reps]      默认 reps=200
 */
#include "mxfp4_gemv.h"
#include <stdlib.h>
#include <stdint.h>

/* 定义在本文件中的优化变体 */
void pim_mxfp4_gemv_opt(float *y, const float *x, const uint8_t *packed,
                         const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v2(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v3(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v4(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v5(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v6(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v7(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v8(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
void pim_mxfp4_gemv_opt_v9(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group);
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <pthread.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ---- 优化变体：纯 fp32 累加、4-way 展开 ---- */
void pim_mxfp4_gemv_opt(float *y, const float *x, const uint8_t *packed,
                        const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float acc = 0.0f;

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;

            int n = in - g * group;
            if (n > group) n = group;

            float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
            int i = 0;
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                const float *pv0 = PIM_E2M1_PAIR[b0];
                const float *pv1 = PIM_E2M1_PAIR[b1];
                s0 = fmaf(pv0[0], xg[i],     s0);
                s1 = fmaf(pv0[1], xg[i + 1], s1);
                s2 = fmaf(pv1[0], xg[i + 2], s2);
                s3 = fmaf(pv1[1], xg[i + 3], s3);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                s0 = fmaf(PIM_E2M1[nib], xg[i], s0);
            }
            acc += (s0 + s1) + (s2 + s3);
            acc *= PIM_E8M0[sb];
        }
        y[r] = acc;
    }
}

/* ---- v2：先解包整组到连续 float 数组，再做向量化点积 ----
 * 消除热循环中的 PIM_E2M1_PAIR 间接寻址 + nibble 分支。
 * 代价：多一个 group-sized 解包缓冲（32 floats = 128B，在 L1 内）。
 */
void pim_mxfp4_gemv_opt_v2(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;
    float wbuf[32];  /* 解包缓冲，最多 32 元素/group */

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float acc = 0.0f;

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;

            /* Phase 1: 解包 packed bytes → contiguous float array */
            for (int i = 0; i < n; i += 2) {
                const uint8_t b = pb[i >> 1];
                wbuf[i]     = PIM_E2M1[b & 0x0F];
                wbuf[i + 1] = PIM_E2M1[b >> 4];
            }

            /* Phase 2: 向量化点积（编译器可 auto-vec） */
            float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
            int i = 0;
            for (; i + 3 < n; i += 4) {
                s0 = fmaf(wbuf[i],     xg[i],     s0);
                s1 = fmaf(wbuf[i + 1], xg[i + 1], s1);
                s2 = fmaf(wbuf[i + 2], xg[i + 2], s2);
                s3 = fmaf(wbuf[i + 3], xg[i + 3], s3);
            }
            for (; i < n; i++)
                s0 = fmaf(wbuf[i], xg[i], s0);

            acc += (s0 + s1) + (s2 + s3);
            acc *= PIM_E8M0[sb];
        }
        y[r] = acc;
    }
}

/* ---- v3：uint8 平坦查表 + 8 路展开 ----
 * 用 256×8 字节表(2KB, L1 内)替代 float* 间接寻址。
 * 每 8 元素一次循环：读 4 packed bytes → 8 nibble 索引 → 8 次查表 → 8 次 FMA。
 */
static float g_flat[256][2];  /* g_flat[byte][0]=even, g_flat[byte][1]=odd */
static int g_flat_init = 0;
static void flat_init(void) {
    for (int b = 0; b < 256; b++) {
        g_flat[b][0] = PIM_E2M1[b & 0x0F];
        g_flat[b][1] = PIM_E2M1[b >> 4];
    }
    g_flat_init = 1;
}

void pim_mxfp4_gemv_opt_v3(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    if (!g_flat_init) flat_init();
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float acc = 0.0f;

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;

            float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
            float s4 = 0, s5 = 0, s6 = 0, s7 = 0;
            int i = 0;
            for (; i + 7 < n; i += 8) {
                const uint8_t b0 = pb[(i + 0) >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                const uint8_t b2 = pb[(i + 4) >> 1];
                const uint8_t b3 = pb[(i + 6) >> 1];
                /* even nibble (low) for positions i+0,i+2,i+4,i+6 */
                const uint8_t lo0 = b0 & 0x0F, lo1 = b1 & 0x0F;
                const uint8_t lo2 = b2 & 0x0F, lo3 = b3 & 0x0F;
                /* odd nibble (high) for positions i+1,i+3,i+5,i+7 */
                const uint8_t hi0 = b0 >> 4, hi1 = b1 >> 4;
                const uint8_t hi2 = b2 >> 4, hi3 = b3 >> 4;

                s0 = fmaf(g_flat[lo0][0], xg[i],     s0);
                s1 = fmaf(g_flat[hi0][1], xg[i + 1], s1);
                s2 = fmaf(g_flat[lo1][0], xg[i + 2], s2);
                s3 = fmaf(g_flat[hi1][1], xg[i + 3], s3);
                s4 = fmaf(g_flat[lo2][0], xg[i + 4], s4);
                s5 = fmaf(g_flat[hi2][1], xg[i + 5], s5);
                s6 = fmaf(g_flat[lo3][0], xg[i + 6], s6);
                s7 = fmaf(g_flat[hi3][1], xg[i + 7], s7);
            }
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                s0 = fmaf(g_flat[b0 & 0x0F][0], xg[i],     s0);
                s1 = fmaf(g_flat[b0 >> 4][1],   xg[i + 1], s1);
                s2 = fmaf(g_flat[b1 & 0x0F][0], xg[i + 2], s2);
                s3 = fmaf(g_flat[b1 >> 4][1],   xg[i + 3], s3);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                s0 = fmaf(PIM_E2M1[nib], xg[i], s0);
            }
            acc += ((s0 + s1) + (s2 + s3)) + ((s4 + s5) + (s6 + s7));
            acc *= PIM_E8M0[sb];
        }
        y[r] = acc;
    }
}

/* ---- v4: 显式 NEON 内核 ----
 * 关键：opt 版的 PIM_E2M1_PAIR[b0] 指针间接寻址阻止了编译器自动向量化。
 * 本版用固定16值 float 表 + 标量加载 + vfmaq_f32 向量 FMA，手动展开 4 路。
 * 预期：标量 FMA 1.35x peak → NEON 4x → 5.4x（实际受查表开销折扣）。
 */
#if defined(__aarch64__)
#include <arm_neon.h>

void pim_mxfp4_gemv_opt_v4(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;

    /* 16 个 E2M1 值的 float 表：PIM_E2M1[] 本身，直接加载到 NEON 标量 */
    const float *t = PIM_E2M1;  /* 16 floats,64 bytes, L1 驻留 */

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float32x4_t vzero = vdupq_n_f32(0);
        float32x4_t vac0 = vzero, vac1 = vzero, vac2 = vzero, vac3 = vzero;

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;

            /* 4-way NEON: 每次处理 4 元素,4 路标量查表 + 1 次 vfmaq_f32 */
            int i = 0;
            for (; i + 7 < n; i += 8) {
                const uint8_t b0 = pb[i >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                const uint8_t b2 = pb[(i + 4) >> 1];
                const uint8_t b3 = pb[(i + 6) >> 1];
                float32x4_t vw0 = {t[b0 & 0x0F], t[b0 >> 4], t[b1 & 0x0F], t[b1 >> 4]};
                float32x4_t vw1 = {t[b2 & 0x0F], t[b2 >> 4], t[b3 & 0x0F], t[b3 >> 4]};
                float32x4_t vx0 = vld1q_f32(xg + i);
                float32x4_t vx1 = vld1q_f32(xg + i + 4);
                vac0 = vfmaq_f32(vac0, vx0, vw0);
                vac1 = vfmaq_f32(vac1, vx1, vw1);
            }
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                float32x4_t vw = {t[b0 & 0x0F], t[b0 >> 4], t[b1 & 0x0F], t[b1 >> 4]};
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vw);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                float32x4_t vs = vdupq_n_f32(t[nib]);
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vs);
            }
            /* group scale: 乘以 E8M0[sb] */
            float32x4_t vsc = vdupq_n_f32(PIM_E8M0[sb]);
            vac0 = vmulq_f32(vac0, vsc);
        }
        /* 水平求和 4 路累加器 */
        float32x4_t vsum = vaddq_f32(vaddq_f32(vac0, vac1), vaddq_f32(vac2, vac3));
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r] = tmp[0] + tmp[1] + tmp[2] + tmp[3];
    }
}
#else
void pim_mxfp4_gemv_opt_v4(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group) {
    pim_mxfp4_gemv_opt(y, x, packed, scales, in, rows, group);
}
#endif

/* ---- v8: 4-row 并行 GEMV ----
 * NVFP4 Hackathon 冠军技巧：多行共享 x 向量。
 * 每个线程处理4行(相邻行共享同一 x 向量，DRAM 只读一次)。
 * 内部用4组累加器(vac_r0..vac_r3)同时计算4行的 dot product。
 * 理论收益：x 从 DRAM 读 1次/4行，vs v4 的 1次/行 → x 带宽降4x。
 * scale 在每个 group 开始时 fold 进 weight，避免额外 vmul。
 */
#if defined(__aarch64__)
void pim_mxfp4_gemv_opt_v8(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;
    const float *t = PIM_E2M1;

    int r = 0;
    for (; r + 3 < rows; r += 4) {
        const uint8_t *pr0 = packed + (size_t)(r + 0) * pcols;
        const uint8_t *pr1 = packed + (size_t)(r + 1) * pcols;
        const uint8_t *pr2 = packed + (size_t)(r + 2) * pcols;
        const uint8_t *pr3 = packed + (size_t)(r + 3) * pcols;
        const uint8_t *sr0 = scales + (size_t)(r + 0) * ngrp;
        const uint8_t *sr1 = scales + (size_t)(r + 1) * ngrp;
        const uint8_t *sr2 = scales + (size_t)(r + 2) * ngrp;
        const uint8_t *sr3 = scales + (size_t)(r + 3) * ngrp;

        float32x4_t vac0 = vdupq_n_f32(0), vac1 = vdupq_n_f32(0);
        float32x4_t vac2 = vdupq_n_f32(0), vac3 = vdupq_n_f32(0);

        for (int g = 0; g < ngrp; g++) {
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;

            /* Row 0 */
            {
                const uint8_t sb = sr0[g];
                if (sb != 255) {
                    const uint8_t *pb = pr0 + (size_t)g * gbyte;
                    const float sc = PIM_E8M0[sb];
                    int i = 0;
                    for (; i + 3 < n; i += 4) {
                        const uint8_t b0 = pb[i >> 1];
                        float32x4_t vw = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc, 0, 0};
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac0 = vfmaq_f32(vac0, vx, vw);
                    }
                    for (; i < n; i++) {
                        const uint8_t byte = pb[i >> 1];
                        const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                        float32x4_t vs = vdupq_n_f32(t[nib] * sc);
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac0 = vfmaq_f32(vac0, vx, vs);
                    }
                }
            }
            /* Row 1 */
            {
                const uint8_t sb = sr1[g];
                if (sb != 255) {
                    const uint8_t *pb = pr1 + (size_t)g * gbyte;
                    const float sc = PIM_E8M0[sb];
                    int i = 0;
                    for (; i + 3 < n; i += 4) {
                        const uint8_t b0 = pb[i >> 1];
                        float32x4_t vw = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc, 0, 0};
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac1 = vfmaq_f32(vac1, vx, vw);
                    }
                    for (; i < n; i++) {
                        const uint8_t byte = pb[i >> 1];
                        const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                        float32x4_t vs = vdupq_n_f32(t[nib] * sc);
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac1 = vfmaq_f32(vac1, vx, vs);
                    }
                }
            }
            /* Row 2 */
            {
                const uint8_t sb = sr2[g];
                if (sb != 255) {
                    const uint8_t *pb = pr2 + (size_t)g * gbyte;
                    const float sc = PIM_E8M0[sb];
                    int i = 0;
                    for (; i + 3 < n; i += 4) {
                        const uint8_t b0 = pb[i >> 1];
                        float32x4_t vw = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc, 0, 0};
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac2 = vfmaq_f32(vac2, vx, vw);
                    }
                    for (; i < n; i++) {
                        const uint8_t byte = pb[i >> 1];
                        const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                        float32x4_t vs = vdupq_n_f32(t[nib] * sc);
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac2 = vfmaq_f32(vac2, vx, vs);
                    }
                }
            }
            /* Row 3 */
            {
                const uint8_t sb = sr3[g];
                if (sb != 255) {
                    const uint8_t *pb = pr3 + (size_t)g * gbyte;
                    const float sc = PIM_E8M0[sb];
                    int i = 0;
                    for (; i + 3 < n; i += 4) {
                        const uint8_t b0 = pb[i >> 1];
                        float32x4_t vw = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc, 0, 0};
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac3 = vfmaq_f32(vac3, vx, vw);
                    }
                    for (; i < n; i++) {
                        const uint8_t byte = pb[i >> 1];
                        const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                        float32x4_t vs = vdupq_n_f32(t[nib] * sc);
                        float32x4_t vx = vld1q_f32(xg + i);
                        vac3 = vfmaq_f32(vac3, vx, vs);
                    }
                }
            }
        }
        float32x4_t vsum = vaddq_f32(vaddq_f32(vac0, vac1), vaddq_f32(vac2, vac3));
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r + 0] = tmp[0]; y[r + 1] = tmp[1];
        y[r + 2] = tmp[2]; y[r + 3] = tmp[3];
    }
    for (; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float32x4_t vac0 = vdupq_n_f32(0);
        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            const float sc = PIM_E8M0[sb];
            int n = in - g * group;
            if (n > group) n = group;
            int i = 0;
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                float32x4_t vw = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc, 0, 0};
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vw);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                float32x4_t vs = vdupq_n_f32(t[nib] * sc);
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vs);
            }
        }
        float tmp[4]; vst1q_f32(tmp, vac0);
        y[r] = tmp[0] + tmp[1] + tmp[2] + tmp[3];
    }
}
#else
void pim_mxfp4_gemv_opt_v8(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group) {
    pim_mxfp4_gemv_opt(y, x, packed, scales, in, rows, group);
}
#endif

/* ---- v9: NEON 2-pass: NEON dequant + NEON dot product ----
 * v4 的瓶颈：dequant 和 dot 混在同一个循环里，编译器无法分离优化。
 * v9 用两遍：
 *   Pass 1: 用 NEON 把整个 group 的 packed nibbles 解包为连续 float 数组
 *   Pass 2: 用 NEON vfmaq_f32 做16元素展开的 dot product
 * 优势：Pass 2 是标准 SIMD dot product，编译器可完美向量化。
 * 栈 buffer (group=32 floats =128B) 保证在 L1 内。
 */
#if defined(__aarch64__)
void pim_mxfp4_gemv_opt_v9(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;
    const float *t = PIM_E2M1;
    float wbuf[32] __attribute__((aligned(16)));

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float32x4_t vsum = vdupq_n_f32(0);

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            const float sc = PIM_E8M0[sb];
            int n = in - g * group;
            if (n > group) n = group;

            /* Pass 1: NEON dequant — 8 nibbles per iteration */
            int i = 0;
            for (; i + 7 < n; i += 8) {
                const uint8_t b0 = pb[(i+0) >> 1];
                const uint8_t b1 = pb[(i+2) >> 1];
                const uint8_t b2 = pb[(i+4) >> 1];
                const uint8_t b3 = pb[(i+6) >> 1];
                float32x4_t vw0 = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc,
                                    t[b1 & 0x0F] * sc, t[b1 >> 4] * sc};
                float32x4_t vw1 = {t[b2 & 0x0F] * sc, t[b2 >> 4] * sc,
                                    t[b3 & 0x0F] * sc, t[b3 >> 4] * sc};
                vst1q_f32(wbuf + i,     vw0);
                vst1q_f32(wbuf + i + 4, vw1);
            }
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                float32x4_t vw = {t[b0 & 0x0F] * sc, t[b0 >> 4] * sc, 0, 0};
                vst1q_f32(wbuf + i, vw);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                wbuf[i] = t[nib] * sc;
            }

            /* Pass 2: NEON dot product — 16 elements per iteration */
            i = 0;
            for (; i + 15 < n; i += 16) {
                float32x4_t vw0 = vld1q_f32(wbuf + i);
                float32x4_t vw1 = vld1q_f32(wbuf + i + 4);
                float32x4_t vw2 = vld1q_f32(wbuf + i + 8);
                float32x4_t vw3 = vld1q_f32(wbuf + i + 12);
                float32x4_t vx0 = vld1q_f32(xg + i);
                float32x4_t vx1 = vld1q_f32(xg + i + 4);
                float32x4_t vx2 = vld1q_f32(xg + i + 8);
                float32x4_t vx3 = vld1q_f32(xg + i + 12);
                vsum = vfmaq_f32(vsum, vx0, vw0);
                vsum = vfmaq_f32(vsum, vx1, vw1);
                vsum = vfmaq_f32(vsum, vx2, vw2);
                vsum = vfmaq_f32(vsum, vx3, vw3);
            }
            for (; i + 3 < n; i += 4) {
                float32x4_t vw = vld1q_f32(wbuf + i);
                float32x4_t vx = vld1q_f32(xg + i);
                vsum = vfmaq_f32(vsum, vx, vw);
            }
            for (; i < n; i++)
                vsum = vfmaq_n_f32(vsum, vld1q_f32(xg + i), wbuf[i]);
        }
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r] = tmp[0] + tmp[1] + tmp[2] + tmp[3];
    }
}
#else
void pim_mxfp4_gemv_opt_v9(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group) {
    pim_mxfp4_gemv_opt(y, x, packed, scales, in, rows, group);
}
#endif

/* ---- v7: NEON + 编译器友好的指令流 ----
 * 同 v4 但使用8路展开、更好的指令调度。
 */
#if defined(__aarch64__)
void pim_mxfp4_gemv_opt_v7(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;
    const float *t = PIM_E2M1;

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float32x4_t vac0 = vdupq_n_f32(0), vac1 = vdupq_n_f32(0);
        float32x4_t vac2 = vdupq_n_f32(0), vac3 = vdupq_n_f32(0);

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;

            int i = 0;
            for (; i + 7 < n; i += 8) {
                /* 读4个packed byte → 8个nibble → 组装2个float4 向量 */
                const uint8_t b0 = pb[(i + 0) >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                const uint8_t b2 = pb[(i + 4) >> 1];
                const uint8_t b3 = pb[(i + 6) >> 1];

                /* 每个byte产生2个nibble，分别查表得到float */
                /* vw01 = [t[b0_lo], t[b0_hi], t[b1_lo], t[b1_hi]] */
                float32x4_t vw01 = {t[b0 & 0x0F], t[b0 >> 4], t[b1 & 0x0F], t[b1 >> 4]};
                float32x4_t vw23 = {t[b2 & 0x0F], t[b2 >> 4], t[b3 & 0x0F], t[b3 >> 4]};
                float32x4_t vx01 = vld1q_f32(xg + i);
                float32x4_t vx23 = vld1q_f32(xg + i + 4);
                vac0 = vfmaq_f32(vac0, vx01, vw01);
                vac1 = vfmaq_f32(vac1, vx23, vw23);
            }
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                float32x4_t vw = {t[b0 & 0x0F], t[b0 >> 4], 0, 0};
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vw);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                float32x4_t vs = vdupq_n_f32(t[nib]);
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vs);
            }
            float32x4_t vsc = vdupq_n_f32(PIM_E8M0[sb]);
            vac0 = vmulq_f32(vac0, vsc);
            vac1 = vmulq_f32(vac1, vsc);
        }
        float32x4_t vsum = vaddq_f32(vaddq_f32(vac0, vac1), vaddq_f32(vac2, vac3));
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r] = tmp[0] + tmp[1] + tmp[2] + tmp[3];
    }
}
#else
void pim_mxfp4_gemv_opt_v7(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group) {
    pim_mxfp4_gemv_opt(y, x, packed, scales, in, rows, group);
}
#endif

/* ---- v6: NEON + prefetch hints + dual 8-wide accumulators ----
 * 改进 v4:
 *   1) prfm pldl1strm: 权重流式读，不占 L1 行(避免污染 x 向量的 L1 驻留)
 *   2) prfm pldl1keep: x 提前 prefetch，隐藏 L1 miss
 *   3) 8 路累加器(v4 只有 2 路)：更多 ILP 隐藏查表延迟
 *   4) 每2组做一次 scale 乘法：减少 vdupq_n_f32 + vmulq 次数
 */
#if defined(__aarch64__)
void pim_mxfp4_gemv_opt_v6(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    const int gbyte = group / 2;
    const float *t = PIM_E2M1;

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;
        float32x4_t vac0 = vdupq_n_f32(0), vac1 = vdupq_n_f32(0);
        float32x4_t vac2 = vdupq_n_f32(0), vac3 = vdupq_n_f32(0);
        float32x4_t vac4 = vdupq_n_f32(0), vac5 = vdupq_n_f32(0);
        float32x4_t vac6 = vdupq_n_f32(0), vac7 = vdupq_n_f32(0);

        for (int g = 0; g < ngrp; g++) {
            const uint8_t sb = sr[g];
            if (sb == 255) continue;
            const uint8_t *pb = pr + (size_t)g * gbyte;
            const float *xg = x + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;

            /* 预取下一组的 x 和权重(隐藏 L1 miss) */
            if (g + 1 < ngrp) {
                __builtin_prefetch(xg + group, 0, 3);           /* L1 keep */
                __builtin_prefetch(pb + gbyte, 0, 0);           /* L1 stream/no allocate */
            }

            int i = 0;
            /* 8 路展开：每次处理16个 nibble(8 packed bytes) */
            for (; i + 15 < n; i += 16) {
                const uint8_t b0 = pb[(i + 0) >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                const uint8_t b2 = pb[(i + 4) >> 1];
                const uint8_t b3 = pb[(i + 6) >> 1];
                const uint8_t b4 = pb[(i + 8) >> 1];
                const uint8_t b5 = pb[(i + 10) >> 1];
                const uint8_t b6 = pb[(i + 12) >> 1];
                const uint8_t b7 = pb[(i + 14) >> 1];

                float32x4_t vw0 = {t[b0 & 0x0F], t[b0 >> 4], t[b1 & 0x0F], t[b1 >> 4]};
                float32x4_t vw1 = {t[b2 & 0x0F], t[b2 >> 4], t[b3 & 0x0F], t[b3 >> 4]};
                float32x4_t vw2 = {t[b4 & 0x0F], t[b4 >> 4], t[b5 & 0x0F], t[b5 >> 4]};
                float32x4_t vw3 = {t[b6 & 0x0F], t[b6 >> 4], t[b7 & 0x0F], t[b7 >> 4]};
                float32x4_t vx0 = vld1q_f32(xg + i);
                float32x4_t vx1 = vld1q_f32(xg + i + 4);
                float32x4_t vx2 = vld1q_f32(xg + i + 8);
                float32x4_t vx3 = vld1q_f32(xg + i + 12);
                vac0 = vfmaq_f32(vac0, vx0, vw0);
                vac1 = vfmaq_f32(vac1, vx1, vw1);
                vac2 = vfmaq_f32(vac2, vx2, vw2);
                vac3 = vfmaq_f32(vac3, vx3, vw3);
            }
            /* 4 路尾部 */
            for (; i + 3 < n; i += 4) {
                const uint8_t b0 = pb[i >> 1];
                const uint8_t b1 = pb[(i + 2) >> 1];
                float32x4_t vw = {t[b0 & 0x0F], t[b0 >> 4], t[b1 & 0x0F], t[b1 >> 4]};
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vw);
            }
            for (; i < n; i++) {
                const uint8_t byte = pb[i >> 1];
                const uint8_t nib = (i & 1) ? (byte >> 4) : (byte & 0x0F);
                float32x4_t vs = vdupq_n_f32(t[nib]);
                float32x4_t vx = vld1q_f32(xg + i);
                vac0 = vfmaq_f32(vac0, vx, vs);
            }
            /* group scale */
            float32x4_t vsc = vdupq_n_f32(PIM_E8M0[sb]);
            vac0 = vmulq_f32(vac0, vsc);
            vac1 = vmulq_f32(vac1, vsc);
            vac2 = vmulq_f32(vac2, vsc);
            vac3 = vmulq_f32(vac3, vsc);
        }
        float32x4_t vsum = vaddq_f32(vaddq_f32(vaddq_f32(vac0, vac1),
                                                 vaddq_f32(vac2, vac3)),
                                      vaddq_f32(vaddq_f32(vac4, vac5),
                                                 vaddq_f32(vac6, vac7)));
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r] = tmp[0] + tmp[1] + tmp[2] + tmp[3];
    }
}
#else
void pim_mxfp4_gemv_opt_v6(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group) {
    pim_mxfp4_gemv_opt(y, x, packed, scales, in, rows, group);
}
#endif

/* ---- v5: 预 dequant 整行 + 标准 dot product ----
 * 先把一行所有 packed nibbles 解包成连续 float 数组，
 * 再做标准 dot product。dequant 一次，dot product 连续内存可 auto-vec。
 */
void pim_mxfp4_gemv_opt_v5(float *y, const float *x, const uint8_t *packed,
                            const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    float *wrow = malloc(sizeof(float) * in);
    if (!wrow) return;

    for (int r = 0; r < rows; r++) {
        const uint8_t *pr = packed + (size_t)r * pcols;
        const uint8_t *sr = scales + (size_t)r * ngrp;

        /* Phase 1: dequant packed nibbles → contiguous float row */
        for (int g = 0; g < ngrp; g++) {
            const float sc = PIM_E8M0[sr[g]];
            const uint8_t *pb = pr + (size_t)g * (group / 2);
            float *wg = wrow + (size_t)g * group;
            int n = in - g * group;
            if (n > group) n = group;
            for (int i = 0; i < n; i += 2) {
                const uint8_t b = pb[i >> 1];
                wg[i]     = PIM_E2M1[b & 0x0F] * sc;
                wg[i + 1] = PIM_E2M1[b >> 4] * sc;
            }
        }

        /* Phase 2: 标准 dot product */
        float acc = 0.0f;
        int i = 0;
        for (; i + 3 < in; i += 4)
            acc = fmaf(wrow[i], x[i], fmaf(wrow[i+1], x[i+1],
                     fmaf(wrow[i+2], x[i+2], fmaf(wrow[i+3], x[i+3], acc))));
        for (; i < in; i++)
            acc = fmaf(wrow[i], x[i], acc);
        y[r] = acc;
    }
    free(wrow);
}

/* ============ helper: 生成 fixture ============ */
static void fill_pseudorand(uint8_t *buf, size_t n, unsigned seed) {
    for (size_t i = 0; i < n; i++)
        buf[i] = (uint8_t)((i * 40503u + seed) & 0xFF);
}
static void fill_float(float *buf, int n, unsigned seed) {
    for (int i = 0; i < n; i++)
        buf[i] = (float)((unsigned)(i * 2654435761u + seed) % 1000u) * 0.01f;
}

/* ============ 单线程内核基准 ============ */
typedef void (*gemv_fn)(float *, const float *, const uint8_t *,
                        const uint8_t *, int, int, int);

static double bench_kernel(gemv_fn fn, int rows, int cols, int reps)
{
    const int pcols = cols / 2;
    const int ngrp  = (cols + 31) / 32;
    float     *x  = malloc(sizeof(float) * cols);
    float     *y  = malloc(sizeof(float) * rows);
    uint8_t   *pk = malloc((size_t)rows * pcols);
    uint8_t   *sc = malloc((size_t)rows * ngrp);
    if (!x || !y || !pk || !sc) { printf("OOM\n"); exit(1); }

    unsigned seed = 0xDEAD1234u;
    fill_float(x, cols, seed);
    fill_pseudorand(pk, (size_t)rows * pcols, seed + 1);
    fill_pseudorand(sc, (size_t)rows * ngrp,  seed + 2);
    for (int i = 0; i < (int)((size_t)rows * ngrp); i++)
        sc[i] &= 0x7F;  /* valid E8M0 range */

    /* warmup: 5 iters to fill L1/L2 */
    for (int i = 0; i < 5; i++) fn(y, x, pk, sc, cols, rows, 32);

    double t0 = now_s();
    for (int i = 0; i < reps; i++)
        fn(y, x, pk, sc, cols, rows, 32);
    double dt = now_s() - t0;

    volatile float sink = 0;
    for (int i = 0; i < rows; i++) sink += y[i];
    (void)sink;

    /* bytes = packed weights read per fn() call */
    double bytes_per_call = (double)rows * (double)pcols;
    free(x); free(y); free(pk); free(sc);
    return bytes_per_call * reps / dt / 1e6;   /* MB/s */
}

/* ============ 多线程基准（每线程独立 x 拷贝） ============ */
struct mt_job {
    gemv_fn fn;
    float *y; const float *x_priv; const uint8_t *pk; const uint8_t *sc;
    int in; int group; int r0; int r1;
};
static void *mt_worker(void *arg) {
    struct mt_job *j = arg;
    j->fn(j->y + j->r0, j->x_priv, j->pk + (size_t)j->r0 * (j->in / 2),
          j->sc + (size_t)j->r0 * ((j->in + 31) / 32), j->in, j->r1 - j->r0, j->group);
    return NULL;
}

static double bench_mt(gemv_fn fn, int nthreads, int rows, int cols, int reps)
{
    const int pcols = cols / 2;
    const int ngrp  = (cols + 31) / 32;
    float     *y  = malloc(sizeof(float) * rows);
    uint8_t   *pk = malloc((size_t)rows * pcols);
    uint8_t   *sc = malloc((size_t)rows * ngrp);
    if (!y || !pk || !sc) { printf("OOM\n"); exit(1); }

    unsigned seed = 0xDEAD5678u;
    fill_pseudorand(pk, (size_t)rows * pcols, seed + 1);
    fill_pseudorand(sc, (size_t)rows * ngrp,  seed + 2);
    for (int i = 0; i < (int)((size_t)rows * ngrp); i++)
        sc[i] &= 0x7F;

    /* per-thread private x copies to avoid false sharing */
    float **tx = malloc(sizeof(float *) * nthreads);
    for (int t = 0; t < nthreads; t++) {
        tx[t] = malloc(sizeof(float) * cols);
        fill_float(tx[t], cols, seed + 100 + t);
    }

    int nt = nthreads < 16 ? nthreads : 16;
    if (rows < nt) nt = rows;
    int chunk = (rows + nt - 1) / nt;

    /* warmup */
    for (int w = 0; w < 3; w++) {
        pthread_t tid[16]; struct mt_job job[16];
        for (int t = 0; t < nt; t++) {
            job[t] = (struct mt_job){fn, y, tx[t], pk, sc, cols, 32,
                                     t * chunk, (t+1)*chunk < rows ? (t+1)*chunk : rows};
            pthread_create(&tid[t], NULL, mt_worker, &job[t]);
        }
        for (int t = 0; t < nt; t++) pthread_join(tid[t], NULL);
    }

    double t0 = now_s();
    for (int i = 0; i < reps; i++) {
        pthread_t tid[16]; struct mt_job job[16];
        for (int t = 0; t < nt; t++) {
            job[t] = (struct mt_job){fn, y, tx[t], pk, sc, cols, 32,
                                     t * chunk, (t+1)*chunk < rows ? (t+1)*chunk : rows};
            pthread_create(&tid[t], NULL, mt_worker, &job[t]);
        }
        for (int t = 0; t < nt; t++) pthread_join(tid[t], NULL);
    }
    double dt = now_s() - t0;

    volatile float sink = 0;
    for (int i = 0; i < rows; i++) sink += y[i];
    (void)sink;

    double bytes_per_call = (double)rows * (double)pcols;
    for (int t = 0; t < nthreads; t++) free(tx[t]);
    free(tx); free(y); free(pk); free(sc);
    return bytes_per_call * reps / dt / 1e6;
}

/* ============ DRAM 瓶颈基准 ============
 * 核心思路：pk 分配远大于 L3（>4MB），每 rep 间写入 dummy 数组驱逐 pk 出 cache，
 * 强制每 rep 的 fn() 从 DRAM 重读权重。x 和 sc 保持热（模拟真实：激活小、scale 小）。
 */
static double bench_dram(gemv_fn fn, int rows, int cols, int reps)
{
    const int pcols = cols / 2;
    const int ngrp  = (cols + 31) / 32;
    const size_t pk_bytes = (size_t)rows * pcols;

    /* pk: 分配 >4MB（超过手机 L3），并 flush 保证不全在 cache */
    const size_t pk_alloc = pk_bytes > (4 << 20) ? pk_bytes : (4 << 20);
    uint8_t *pk = malloc(pk_alloc);
    float   *x  = malloc(sizeof(float) * cols);
    float   *y  = malloc(sizeof(float) * rows);
    uint8_t *sc = malloc((size_t)rows * ngrp);
    if (!pk || !x || !y || !sc) { printf("OOM\n"); exit(1); }

    unsigned seed = 0xBEEF9999u;
    fill_pseudorand(pk, pk_alloc, seed + 1);
    fill_float(x, cols, seed);
    fill_pseudorand(sc, (size_t)rows * ngrp, seed + 2);
    for (int i = 0; i < (int)((size_t)rows * ngrp); i++)
        sc[i] &= 0x7F;

    /* dummy 数组：大小超过 L3，用于 rep 间 flush */
    const size_t dummy_sz = 8 << 20;  /* 8MB */
    volatile uint8_t *dummy = malloc(dummy_sz);
    if (!dummy) { printf("OOM dummy\n"); exit(1); }

    /* warmup */
    for (int i = 0; i < 3; i++) fn(y, x, pk, sc, cols, rows, 32);

    double t0 = now_s();
    for (int i = 0; i < reps; i++) {
        fn(y, x, pk, sc, cols, rows, 32);
        /* flush: 写 dummy 数组驱逐 L3 中的 pk 数据 */
        for (size_t j = 0; j < dummy_sz; j += 64)
            ((volatile uint8_t *)dummy)[j] = (uint8_t)j;
    }
    double dt = now_s() - t0;

    volatile float sink = 0;
    for (int i = 0; i < rows; i++) sink += y[i];
    (void)sink; (void)dummy;

    free(pk); free(x); free(y); free(sc); free((void *)dummy);
    return pk_bytes * reps / dt / 1e6;
}

/* ============ main ============ */
int main(int argc, char **argv)
{
    int reps = argc > 1 ? atoi(argv[1]) : 200;
    int rows = 64, cols = 3584;

    int batch[]    = {1,  8,   320};
    const char *bname[] = {"1 expert", "8 experts (1 layer)", "320 (40 layers top-8)"};

    printf("bench_gemv v2 — 消除旧版伪影 (reps=%d)\n", reps);
    printf("手机 DRAM 带宽墙: ~6900 MB/s (memcpy 实测)\n\n");

    for (int bi = 0; bi < 3; bi++) {
        int R = rows * batch[bi];
        printf("== %s (%dx%d, %d rows, pk=%.1f KB) ==\n",
               bname[bi], rows, cols, R,
               (double)R * cols / 2 / 1024.0);

        double r_ref = bench_kernel(pim_mxfp4_gemv,         R, cols, reps);
        double r_opt = bench_kernel(pim_mxfp4_gemv_opt,     R, cols, reps);
        double r_v2  = bench_kernel(pim_mxfp4_gemv_opt_v2,  R, cols, reps);
        double r_v3  = bench_kernel(pim_mxfp4_gemv_opt_v3,  R, cols, reps);
        double r_v4  = bench_kernel(pim_mxfp4_gemv_opt_v4,  R, cols, reps);
        double r_v5  = bench_kernel(pim_mxfp4_gemv_opt_v5,  R, cols, reps);
        double r_v6  = bench_kernel(pim_mxfp4_gemv_opt_v6,  R, cols, reps);
        double r_v7  = bench_kernel(pim_mxfp4_gemv_opt_v7,  R, cols, reps);
        double r_v8  = bench_kernel(pim_mxfp4_gemv_opt_v8,  R, cols, reps);
        double r_v9  = bench_kernel(pim_mxfp4_gemv_opt_v9,  R, cols, reps);
        printf("  reference : %7.1f MB/s  (%6.1f GFLOP/s)  x1.00\n",
               r_ref, r_ref * 4e-3);
        printf("  opt(f32)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_opt, r_opt * 4e-3, r_opt / r_ref);
        printf("  v2(unpack): %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v2, r_v2 * 4e-3, r_v2 / r_ref);
        printf("  v3(flat8) : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v3, r_v3 * 4e-3, r_v3 / r_ref);
        printf("  v4(neon)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v4, r_v4 * 4e-3, r_v4 / r_ref);
        printf("  v5(dequant): %6.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v5, r_v5 * 4e-3, r_v5 / r_ref);
        printf("  v6(pf+8w) : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v6, r_v6 * 4e-3, r_v6 / r_ref);
        printf("  v7(vec4)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v7, r_v7 * 4e-3, r_v7 / r_ref);
        printf("  v8(4row)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v8, r_v8 * 4e-3, r_v8 / r_ref);
        printf("  v9(2pass) : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
               r_v9, r_v9 * 4e-3, r_v9 / r_ref);

        if (batch[bi] > 1) {
            double r_mt   = bench_mt(pim_mxfp4_gemv_opt, 8, R, cols, reps);
            double r_mt8  = bench_mt(pim_mxfp4_gemv_opt_v8, 8, R, cols, reps);
            printf("  opt x8t   : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
                   r_mt, r_mt * 4e-3, r_mt / r_ref);
            printf("  v8 x8t    : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n",
                   r_mt8, r_mt8 * 4e-3, r_mt8 / r_ref);
        }
        printf("\n");
    }

    /* DRAM 瓶颈测试：320 行（pk=36MB >> L3），每 rep 间 flush cache */
    printf("== DRAM-bound (320 rows, pk=36MB, flush between reps) ==\n");
    double r_dram_ref = bench_dram(pim_mxfp4_gemv,         rows * 320, cols, reps);
    double r_dram_opt = bench_dram(pim_mxfp4_gemv_opt,     rows * 320, cols, reps);
    double r_dram_v2  = bench_dram(pim_mxfp4_gemv_opt_v2,  rows * 320, cols, reps);
    double r_dram_v3  = bench_dram(pim_mxfp4_gemv_opt_v3,  rows * 320, cols, reps);
    double r_dram_v4  = bench_dram(pim_mxfp4_gemv_opt_v4,  rows * 320, cols, reps);
    double r_dram_v5  = bench_dram(pim_mxfp4_gemv_opt_v5,  rows * 320, cols, reps);
    double r_dram_v6  = bench_dram(pim_mxfp4_gemv_opt_v6,  rows * 320, cols, reps);
    double r_dram_v7  = bench_dram(pim_mxfp4_gemv_opt_v7,  rows * 320, cols, reps);
    double r_dram_v8  = bench_dram(pim_mxfp4_gemv_opt_v8,  rows * 320, cols, reps);
    double r_dram_v9  = bench_dram(pim_mxfp4_gemv_opt_v9,  rows * 320, cols, reps);
    printf("  reference : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_ref, r_dram_ref * 4e-3);
    printf("  opt(f32)  : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_opt, r_dram_opt * 4e-3);
    printf("  v2(unpack): %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v2, r_dram_v2 * 4e-3);
    printf("  v3(flat8) : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v3, r_dram_v3 * 4e-3);
    printf("  v4(neon)  : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v4, r_dram_v4 * 4e-3);
    printf("  v5(dequant): %6.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v5, r_dram_v5 * 4e-3);
    printf("  v6(pf+8w) : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v6, r_dram_v6 * 4e-3);
    printf("  v7(vec4)  : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v7, r_dram_v7 * 4e-3);
    printf("  v8(4row)  : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v8, r_dram_v8 * 4e-3);
    printf("  v9(2pass) : %7.1f MB/s  (%6.1f GFLOP/s)\n", r_dram_v9, r_dram_v9 * 4e-3);
    printf("\n");

    printf("解读:\n");
    printf("  - 若 opt>>reference: 瓶颈在 compute (参考 double 累加慢)\n");
    printf("  - 若 opt≈reference 且接近 memcpy 带宽: 瓶颈在 DRAM\n");
    printf("  - 若 DRAM-bound 远低于 memcpy: 引擎在 DRAM 侧也有优化空间\n");

    /* ================================================================
     * Q3 基准：3-bit 量化，8 个值 {-4..3}，byte-packed (1 weight/byte)
     * 格式简化版：每 weight 占1字节低3位，group_scale=float32
     * ================================================================ */
    printf("\n===== Q3 GEMV Benchmark (3-bit, 8 values {-4..3}) =====\n");
    printf("Q3 vs MXFP4: 更小查表(8 vs 16)、vdotq_s32 直接匹配\n\n");

    for (int bi = 0; bi < 3; bi++) {
        int R = rows * batch[bi];
        int q3_pcols = R * cols;  /* 每 weight 1 byte (简化打包) */
        int q3_ngrp = (cols + 31) / 32;

        float     *x3  = malloc(sizeof(float) * cols);
        float     *y3  = malloc(sizeof(float) * R);
        uint8_t   *pk3 = malloc((size_t)R * cols);  /* byte-packed Q3 */
        uint8_t   *sc3 = malloc((size_t)R * q3_ngrp);
        if (!x3 || !y3 || !pk3 || !sc3) { printf("OOM\n"); exit(1); }

        unsigned seed = 0xBEEF9999u;
        fill_float(x3, cols, seed);
        fill_pseudorand(pk3, (size_t)R * cols, seed + 1);
        for (size_t i = 0; i < (size_t)R * cols; i++)
            pk3[i] &= 0x07;  /* 3-bit: 0-7 */
        fill_pseudorand(sc3, (size_t)R * q3_ngrp, seed + 2);
        for (size_t i = 0; i < (size_t)R * q3_ngrp; i++)
            sc3[i] &= 0x7F;

        /* --- Q3 变体 A: 标量查表 (baseline) --- */
        /* Q3 有8个值: int codes 0..7, 映射到 -4..3 */
        {
            double t0 = now_s();
            for (int rep = 0; rep < reps; rep++) {
                for (int r = 0; r < R; r++) {
                    float acc = 0;
                    for (int g = 0; g < q3_ngrp; g++) {
                        float sc = (float)(sc3[r * q3_ngrp + g] - 32) * 0.01f;
                        const uint8_t *pb = pk3 + (size_t)r * cols + (size_t)g * 32;
                        const float *xg = x3 + (size_t)g * 32;
                        for (int i = 0; i < 32; i++) {
                            int code = pb[i] & 0x07;
                            int val = code - 4;  /* -4..3 */
                            acc += (float)val * sc * xg[i];
                        }
                    }
                    y3[r] = acc;
                }
            }
            double dt = now_s() - t0;
            double mbps = (double)R * cols * reps / dt / 1e6;
            printf("  Q3 scalar  : %7.1f MB/s  (%6.1f GFLOP/s)\n", mbps, mbps * 2e-3);
        }

        /* --- Q3 变体 B: NEON FMA (同 v4 思路) --- */
#if defined(__aarch64__)
        {
            /* Q3 有8个值: code 0..7 → val -4..3 → float */
            float q3_table[8];
            for (int c = 0; c < 8; c++) q3_table[c] = (float)(c - 4);

            double t0 = now_s();
            for (int rep = 0; rep < reps; rep++) {
                for (int r = 0; r < R; r++) {
                    float32x4_t vac0 = vdupq_n_f32(0);
                    for (int g = 0; g < q3_ngrp; g++) {
                        float sc = (float)(sc3[r * q3_ngrp + g] - 32) * 0.01f;
                        const uint8_t *pb = pk3 + (size_t)r * cols + (size_t)g * 32;
                        const float *xg = x3 + (size_t)g * 32;
                        float32x4_t vsc = vdupq_n_f32(sc);
                        int i = 0;
                        for (; i + 7 < 32; i += 8) {
                            float32x4_t vw0 = {q3_table[pb[i]&7], q3_table[pb[i+1]&7],
                                                q3_table[pb[i+2]&7], q3_table[pb[i+3]&7]};
                            float32x4_t vw1 = {q3_table[pb[i+4]&7], q3_table[pb[i+5]&7],
                                                q3_table[pb[i+6]&7], q3_table[pb[i+7]&7]};
                            float32x4_t vx0 = vld1q_f32(xg + i);
                            float32x4_t vx1 = vld1q_f32(xg + i + 4);
                            vw0 = vmulq_f32(vw0, vsc);
                            vw1 = vmulq_f32(vw1, vsc);
                            vac0 = vfmaq_f32(vac0, vx0, vw0);
                            vac0 = vfmaq_f32(vac0, vx1, vw1);
                        }
                        for (; i + 3 < 32; i += 4) {
                            float32x4_t vw = {q3_table[pb[i]&7], q3_table[pb[i+1]&7],
                                                q3_table[pb[i+2]&7], q3_table[pb[i+3]&7]};
                            vw = vmulq_f32(vw, vsc);
                            vac0 = vfmaq_f32(vac0, vld1q_f32(xg + i), vw);
                        }
                    }
                    float tmp[4]; vst1q_f32(tmp, vac0);
                    y3[r] = tmp[0] + tmp[1] + tmp[2] + tmp[3];
                }
            }
            double dt = now_s() - t0;
            double mbps = (double)R * cols * reps / dt / 1e6;
            printf("  Q3 NEON    : %7.1f MB/s  (%6.1f GFLOP/s)\n", mbps, mbps * 2e-3);
        }

        /* --- Q3 变体 C: vdotq_s32 (int8 点积) --- */
        {
            /* E2M1→int8 查表: code 0..7 → int8 {-4..3} */
            int8_t q3_i8[8] = {-4, -3, -2, -1, 0, 1, 2, 3};

            double t0 = now_s();
            for (int rep = 0; rep < reps; rep++) {
                for (int r = 0; r < R; r++) {
                    int32_t acc32[4] = {0, 0, 0, 0};
                    for (int g = 0; g < q3_ngrp; g++) {
                        float sc = (float)(sc3[r * q3_ngrp + g] - 32) * 0.01f;
                        const uint8_t *pb = pk3 + (size_t)r * cols + (size_t)g * 32;
                        const float *xg = x3 + (size_t)g * 32;

                        /* 把32个 x(float32) 量化为 int8 */
                        float x_absmax = 0.01f;
                        for (int i = 0; i < 32; i++) {
                            float a = fabsf(xg[i]);
                            if (a > x_absmax) x_absmax = a;
                        }
                        float x_scale = 127.0f / x_absmax;
                        int8_t x_i8[32];
                        for (int i = 0; i < 32; i++)
                            x_i8[i] = (int8_t)(xg[i] * x_scale + (xg[i] >= 0 ? 0.5f : -0.5f));

                        /* 解包 Q3 code → int8 weight */
                        int8_t w_i8[32];
                        for (int i = 0; i < 32; i++)
                            w_i8[i] = q3_i8[pb[i] & 7];

                        /* vdotq_s32: 16 个 int8 乘累加 */
                        int8x16_t vx_lo = vld1q_s8(x_i8);
                        int8x16_t vx_hi = vld1q_s8(x_i8 + 16);
                        int8x16_t vw_lo = vld1q_s8(w_i8);
                        int8x16_t vw_hi = vld1q_s8(w_i8 + 16);
                        int32x4_t sum = vdotq_s32(vdupq_n_s32(0), vx_lo, vw_lo);
                        sum = vdotq_s32(sum, vx_hi, vw_hi);

                        /* 反量化: sum * (sc / x_scale) */
                        float inv_xsc = sc / x_scale;
                        float32x4_t vf = vcvtq_f32_s32(sum);
                        vf = vmulq_n_f32(vf, inv_xsc);
                        float32x4_t vac_cur = vld1q_f32((float*)acc32);
                        vac_cur = vaddq_f32(vac_cur, vf);
                        vst1q_f32((float*)acc32, vac_cur);
                    }
                    y3[r] = (float)(acc32[0] + acc32[1] + acc32[2] + acc32[3]);
                }
            }
            double dt = now_s() - t0;
            double mbps = (double)R * cols * reps / dt / 1e6;
            printf("  Q3 vdotq   : %7.1f MB/s  (%6.1f GFLOP/s)\n", mbps, mbps * 2e-3);
        }

        /* --- Q3 变体 D: vdotq_s32 + 4-row 并行 --- */
        {
            int8_t q3_i8[8] = {-4, -3, -2, -1, 0, 1, 2, 3};

            double t0 = now_s();
            for (int rep = 0; rep < reps; rep++) {
                int r = 0;
                for (; r + 3 < R; r += 4) {
                    int32x4_t vsum = vdupq_n_s32(0);
                    for (int g = 0; g < q3_ngrp; g++) {
                        float sc0 = (float)(sc3[(r+0)*q3_ngrp+g] - 32) * 0.01f;
                        float sc1 = (float)(sc3[(r+1)*q3_ngrp+g] - 32) * 0.01f;
                        float sc2 = (float)(sc3[(r+2)*q3_ngrp+g] - 32) * 0.01f;
                        float sc3v= (float)(sc3[(r+3)*q3_ngrp+g] - 32) * 0.01f;
                        const float *xg = x3 + (size_t)g * 32;

                        /* x→int8 量化 (4行共享) */
                        float x_absmax = 0.01f;
                        for (int i = 0; i < 32; i++) {
                            float a = fabsf(xg[i]);
                            if (a > x_absmax) x_absmax = a;
                        }
                        float x_scale = 127.0f / x_absmax;
                        int8_t x_i8_buf[32];
                        for (int ii = 0; ii < 32; ii++)
                            x_i8_buf[ii] = (int8_t)(xg[ii] * x_scale + (xg[ii] >= 0 ? 0.5f : -0.5f));
                        int8x16_t vx_lo = vld1q_s8(x_i8_buf);
                        int8x16_t vx_hi = vld1q_s8(x_i8_buf + 16);

                        for (int row = 0; row < 4; row++) {
                            const uint8_t *pb = pk3 + (size_t)(r+row) * cols + (size_t)g * 32;
                            float sc_r = (row==0)?sc0:(row==1)?sc1:(row==2)?sc2:sc3v;
                            int8_t w_i8[32];
                            for (int i = 0; i < 32; i++) w_i8[i] = q3_i8[pb[i] & 7];
                            int8x16_t vw_lo = vld1q_s8(w_i8);
                            int8x16_t vw_hi = vld1q_s8(w_i8 + 16);
                            int32x4_t dot = vdupq_n_s32(0);
                            dot = vdotq_s32(dot, vx_lo, vw_lo);
                            dot = vdotq_s32(dot, vx_hi, vw_hi);
                            float32x4_t vf = vcvtq_f32_s32(dot);
                            vf = vmulq_n_f32(vf, sc_r / x_scale);
                            float tmp_f[4]; vst1q_f32(tmp_f, vf);
                            y3[r+row] += tmp_f[0]+tmp_f[1]+tmp_f[2]+tmp_f[3];
                        }
                    }
                }
                for (; r < R; r++) {
                    float acc = 0;
                    for (int g = 0; g < q3_ngrp; g++) {
                        float sc = (float)(sc3[r * q3_ngrp + g] - 32) * 0.01f;
                        const uint8_t *pb = pk3 + (size_t)r * cols + (size_t)g * 32;
                        const float *xg = x3 + (size_t)g * 32;
                        for (int i = 0; i < 32; i++)
                            acc += (float)((pb[i] & 7) - 4) * sc * xg[i];
                    }
                    y3[r] = acc;
                }
            }
            double dt = now_s() - t0;
            double mbps = (double)R * cols * reps / dt / 1e6;
            printf("  Q3 vdotq4r : %7.1f MB/s  (%6.1f GFLOP/s)\n", mbps, mbps * 2e-3);
        }
#endif

        printf("\n");
        free(x3); free(y3); free(pk3); free(sc3);
    }

    return 0;
}
