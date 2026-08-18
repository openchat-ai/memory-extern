/* bench_gemv.c — 引擎性能基准：参考内核 vs 优化变体。
 *
 * 目标：找到"把 CPU 引擎推到带宽墙"的优化路径（引擎优化课题）。
 * 用 fixture 的单专家规模（64×3584）做 GEMV 微基准，量吞吐 GB/s 与
 * GFLOP/s，对照手机 DDR 带宽与理论算力。
 *
 * 三种实现：
 *   0) pim_mxfp4_gemv          —— 参考（double 累加，逐位契约）
 *   1) pim_mxfp4_gemv_opt      —— 优化：按 32 元素 group 展开成 fp32 一次点积，
 *                                 分组内用 4 路 fp32 累加器（不逐位，仅性能对比）
 *   2) 直接 dequant + dot（最朴素对照，量上限）
 *
 * 用法: ./bench_gemv [reps]
 * 输出每版: MB/s(读权重) / GFLOP/s(算乘加) / 相对参考加速比
 */
#include "mxfp4_gemv.h"
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

/* ---- 多线程参考：按行分块，每线程独立算行区间（逐位契约不受影响） ---- */
struct mt_job {
    void (*fn)(float *, const float *, const uint8_t *, const uint8_t *, int, int, int);
    float *y; const float *x; const uint8_t *pk; const uint8_t *sc;
    int in; int group; int r0; int r1;
};
static void *mt_worker(void *arg) {
    struct mt_job *j = arg;
    j->fn(j->y + j->r0, j->x, j->pk + (size_t)j->r0 * (j->in / 2),
          j->sc + (size_t)j->r0 * ((j->in + 31) / 32), j->in, j->r1 - j->r0, j->group);
    return NULL;
}
static void gemv_mt(int nthreads,
                    void (*fn)(float *, const float *, const uint8_t *, const uint8_t *, int, int, int),
                    float *y, const float *x, const uint8_t *pk, const uint8_t *sc,
                    int in, int rows, int group)
{
    pthread_t tid[16];
    struct mt_job job[16];
    int n = nthreads < 16 ? nthreads : 16;
    if (rows < n) n = rows;
    int chunk = (rows + n - 1) / n;
    for (int t = 0; t < n; t++) {
        job[t] = (struct mt_job){fn, y, x, pk, sc, in, group, t * chunk,
                                 (t + 1) * chunk < rows ? (t + 1) * chunk : rows};
        pthread_create(&tid[t], NULL, mt_worker, &job[t]);
    }
    for (int t = 0; t < n; t++) pthread_join(tid[t], NULL);
}

/* ---- 优化变体：同参考的展开顺序，但纯 fp32 累加、去掉 8-way double 树 ---- */
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

            /* 4-way fp32 partial sums; the reference splits to allow vectorisation */
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

/* ---- 朴素对照：先全部 dequant 成 fp32，再常规 dot ---- */
void pim_mxfp4_gemv_naive(float *y, const float *x, const uint8_t *packed,
                          const uint8_t *scales, int in, int rows, int group)
{
    const int pcols = in / 2;
    const int ngrp  = (in + group - 1) / group;
    float *w = malloc(sizeof(float) * (size_t)rows * in);
    if (!w) return;

    pim_mxfp4_dequant(w, packed, scales, rows, pcols, group);
    for (int r = 0; r < rows; r++) {
        const float *wr = w + (size_t)r * in;
        float acc = 0.0f;
        for (int i = 0; i < in; i++)
            acc = fmaf(wr[i], x[i], acc);
        y[r] = acc;
    }
    free(w);
}

static double bench(int rows, int cols, int reps,
                    void (*fn)(float *, const float *, const uint8_t *,
                               const uint8_t *, int, int, int))
{
    float *x = malloc(sizeof(float) * cols);
    float *y = malloc(sizeof(float) * rows);
    uint8_t *pk = malloc(rows * cols / 2);
    uint8_t *sc = malloc(rows * ((cols + 31) / 32));
    if (!x || !y || !pk || !sc) { printf("OOM\n"); exit(1); }

    static volatile unsigned g_seed = 0;
    unsigned seed = (unsigned)time(NULL) ^ (unsigned)now_s() ^ g_seed;
    for (int i = 0; i < cols; i++) x[i] = (float)((i * 2654435761u + seed) % 1000u) * 0.01f;
    for (int i = 0; i < rows * cols / 2; i++) pk[i] = (uint8_t)((i * 40503u + seed) & 0xFF);
    for (int i = 0; i < rows * ((cols + 31) / 32); i++) sc[i] = (uint8_t)((i * 97u + seed) & 0x7F);

    for (int i = 0; i < 3; i++) fn(y, x, pk, sc, cols, rows, 32);

    double t0 = now_s();
    for (int i = 0; i < reps; i++) {
        g_seed = (g_seed * 1103515245u + 12345u) ^ (unsigned)(uintptr_t)fn;
        for (int k = 0; k < cols; k++) x[k] += 1e-6f * (float)(int)((g_seed >> (k & 31)) & 1u);
        fn(y, x, pk, sc, cols, rows, 32);
    }
    double dt = now_s() - t0;
    volatile float sink = 0;
    for (int i = 0; i < rows; i++) sink += y[i];

    double bytes = (double)reps * (double)rows * (double)cols / 2;
    free(x); free(y); free(pk); free(sc);
    (void)sink;
    return bytes / dt / 1e6;   /* MB/s */
}

static double bench_mt(int nthreads, int rows, int cols, int reps,
                       void (*fn)(float *, const float *, const uint8_t *,
                                  const uint8_t *, int, int, int))
{
    float *x = malloc(sizeof(float) * cols);
    float *y = malloc(sizeof(float) * rows);
    uint8_t *pk = malloc(rows * cols / 2);
    uint8_t *sc = malloc(rows * ((cols + 31) / 32));
    if (!x || !y || !pk || !sc) { printf("OOM\n"); exit(1); }

    static volatile unsigned g_seed = 0;
    unsigned seed = (unsigned)time(NULL) ^ (unsigned)now_s() ^ g_seed;
    for (int i = 0; i < cols; i++) x[i] = (float)((i * 2654435761u + seed) % 1000u) * 0.01f;
    for (int i = 0; i < rows * cols / 2; i++) pk[i] = (uint8_t)((i * 40503u + seed) & 0xFF);
    for (int i = 0; i < rows * ((cols + 31) / 32); i++) sc[i] = (uint8_t)((i * 97u + seed) & 0x7F);

    for (int i = 0; i < 3; i++) gemv_mt(nthreads, fn, y, x, pk, sc, cols, rows, 32);

    double t0 = now_s();
    for (int i = 0; i < reps; i++) {
        g_seed = (g_seed * 1103515245u + 12345u) ^ (unsigned)(uintptr_t)fn;
        for (int k = 0; k < cols; k++) x[k] += 1e-6f * (float)(int)((g_seed >> (k & 31)) & 1u);
        gemv_mt(nthreads, fn, y, x, pk, sc, cols, rows, 32);
    }
    double dt = now_s() - t0;
    volatile float sink = 0;
    for (int i = 0; i < rows; i++) sink += y[i];

    double bytes = (double)reps * (double)rows * (double)cols / 2;
    free(x); free(y); free(pk); free(sc);
    (void)sink;
    return bytes / dt / 1e6;
}

int main(int argc, char **argv) {
    int reps = argc > 1 ? atoi(argv[1]) : 100;
    int rows = 64, cols = 3584;   /* fixture: single expert */
    double bytes = (double)rows * (double)cols / 2;

    /* 批粒度:单专家 vs 8 专家(一层 top-8)vs 40 层全量 */
    int batch[] = {1, 8, 320};
    const char *bname[] = {"1 expert", "8 experts (1 layer)", "320 (40 layers top-8)"};

    for (int bi = 0; bi < 3; bi++) {
        int R = rows * batch[bi];
        printf("== %s (%dx%d, %d rows total) ==\n", bname[bi], rows, cols, R);
        double r_ref = bench(R, cols, reps, pim_mxfp4_gemv);
        double r_opt = bench(R, cols, reps, pim_mxfp4_gemv_opt);
        printf("  reference : %7.1f MB/s  (%6.1f GFLOP/s)  x1.00\n", r_ref, r_ref * 4e-3);
        printf("  opt(f32)  : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n", r_opt, r_opt * 4e-3, r_opt / r_ref);
        if (batch[bi] > 1) {
            double r_mt = bench_mt(8, R, cols, reps, pim_mxfp4_gemv_opt);
            printf("  opt x8t   : %7.1f MB/s  (%6.1f GFLOP/s)  x%.2f\n", r_mt, r_mt * 4e-3, r_mt / r_ref);
        }
    }
    printf("(GFLOP/s = MB/s x 4; 手机DRAM带宽墙≈6900 MB/s(实测 memcpy))\n");
    return 0;
}
