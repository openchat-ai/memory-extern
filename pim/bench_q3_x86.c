/* bench_q3_x86.c — Q3 (3-bit) GEMV x86 AVX2 全变体对比
 * 格式同 bench_q3.c: 每 weight 1 byte 低3位 (code 0..7 → val -4..3)
 * group=32, group_scale=byte(映射到 float)
 *
 * 编译 (WSL/Linux):
 *   gcc -O3 -mavx2 -mfma -march=x86-64-v3 -o bench_q3_x86 bench_q3_x86.c -lm -lpthread
 *
 * 在 EPYC 服务器上跑:
 *   ./bench_q3_x86 500
 */
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#include <immintrin.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static const float Q3_F[8] = {-4, -3, -2, -1, 0, 1, 2, 3};

static void fill_pseudorand(uint8_t *buf, size_t n, unsigned seed) {
    for (size_t i = 0; i < n; i++)
        buf[i] = (uint8_t)((i * 40503u + seed) & 0xFF);
}
static void fill_float(float *buf, int n, unsigned seed) {
    for (int i = 0; i < n; i++)
        buf[i] = (float)((unsigned)(i * 2654435761u + seed) % 1000u) * 0.01f;
}

/* scalar double baseline */
static void q3_scalar(double *y, const float *x, const uint8_t *pk,
                      const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    for (int r = 0; r < rows; r++) {
        double acc = 0;
        for (int g = 0; g < ngrp; g++) {
            double s = (double)(sc[r * ngrp + g] - 32) * 0.01;
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            for (int i = 0; i < n; i++)
                acc += (double)Q3_F[pb[i] & 7] * s * (double)xg[i];
        }
        y[r] = (float)acc;
    }
}

/* scalar float + 4-way unroll */
static void q3_opt(float *y, const float *x, const uint8_t *pk,
                   const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    for (int r = 0; r < rows; r++) {
        float acc = 0;
        for (int g = 0; g < ngrp; g++) {
            float s = (float)(sc[r * ngrp + g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            float s0=0,s1=0,s2=0,s3=0;
            int i = 0;
            for (; i+3 < n; i+=4) {
                s0 += Q3_F[pb[i]&7] * xg[i];
                s1 += Q3_F[pb[i+1]&7] * xg[i+1];
                s2 += Q3_F[pb[i+2]&7] * xg[i+2];
                s3 += Q3_F[pb[i+3]&7] * xg[i+3];
            }
            for (; i < n; i++) s0 += Q3_F[pb[i]&7] * xg[i];
            acc += (s0+s1+s2+s3) * s;
        }
        y[r] = acc;
    }
}

/* flat table + 8-way */
static void q3_v3(float *y, const float *x, const uint8_t *pk,
                  const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    for (int r = 0; r < rows; r++) {
        float acc = 0;
        for (int g = 0; g < ngrp; g++) {
            float s = (float)(sc[r * ngrp + g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            float s0=0,s1=0,s2=0,s3=0,s4=0,s5=0,s6=0,s7=0;
            int i = 0;
            for (; i+7 < n; i+=8) {
                s0 += Q3_F[pb[i]&7]*xg[i];     s1 += Q3_F[pb[i+1]&7]*xg[i+1];
                s2 += Q3_F[pb[i+2]&7]*xg[i+2]; s3 += Q3_F[pb[i+3]&7]*xg[i+3];
                s4 += Q3_F[pb[i+4]&7]*xg[i+4]; s5 += Q3_F[pb[i+5]&7]*xg[i+5];
                s6 += Q3_F[pb[i+6]&7]*xg[i+6]; s7 += Q3_F[pb[i+7]&7]*xg[i+7];
            }
            for (; i < n; i++) s0 += Q3_F[pb[i]&7]*xg[i];
            acc += (s0+s1+s2+s3+s4+s5+s6+s7) * s;
        }
        y[r] = acc;
    }
}

/* helper: horizontal sum of __m256 */
static inline float hsum256(__m256 v) {
    __m128 hi = _mm256_extractf128_ps(v, 1);
    __m128 lo = _mm256_castps256_ps128(v);
    __m128 s = _mm_add_ps(hi, lo);
    s = _mm_hadd_ps(s, s);
    s = _mm_hadd_ps(s, s);
    return _mm_cvtss_f32(s);
}

/* AVX2: gather 查表 + FMA
 * 3-byte → zero-extend to 8x int32 → mask &7 → gather from Q3_F → mul scale → FMA
 */
static void q3_avx2_gather(float *y, const float *x, const uint8_t *pk,
                           const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const __m256i vm3 = _mm256_set1_epi32(7);

    for (int r = 0; r < rows; r++) {
        __m256 vsum = _mm256_setzero_ps();
        for (int g = 0; g < ngrp; g++) {
            float sf = (float)(sc[r * ngrp + g] - 32) * 0.01f;
            __m256 vs = _mm256_set1_ps(sf);
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            int i = 0;
            for (; i + 8 <= n; i += 8) {
                __m128i b8 = _mm_loadl_epi64((const __m128i*)(pb + i));
                __m256i idx = _mm256_and_si256(_mm256_cvtepu8_epi32(b8), vm3);
                __m256 vw = _mm256_mul_ps(_mm256_i32gather_ps(Q3_F, idx, 4), vs);
                vsum = _mm256_fmadd_ps(vw, _mm256_loadu_ps(xg + i), vsum);
            }
            for (; i < n; i++)
                vsum = _mm256_fmadd_ps(_mm256_set1_ps(Q3_F[pb[i]&7]*sf),
                                       _mm256_set1_ps(xg[i]), vsum);
        }
        y[r] = hsum256(vsum);
    }
}

/* AVX2 2-pass: decode → buffer, then pure FMA dot */
static void q3_avx2_2pass(float *y, const float *x, const uint8_t *pk,
                          const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const __m256i vm3 = _mm256_set1_epi32(7);
    float wbuf[32] __attribute__((aligned(32)));

    for (int r = 0; r < rows; r++) {
        __m256 vsum = _mm256_setzero_ps();
        for (int g = 0; g < ngrp; g++) {
            float sf = (float)(sc[r * ngrp + g] - 32) * 0.01f;
            __m256 vs = _mm256_set1_ps(sf);
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            /* pass 1: dequant */
            int i = 0;
            for (; i + 8 <= n; i += 8) {
                __m128i b8 = _mm_loadl_epi64((const __m128i*)(pb + i));
                __m256i idx = _mm256_and_si256(_mm256_cvtepu8_epi32(b8), vm3);
                _mm256_store_ps(wbuf + i, _mm256_mul_ps(_mm256_i32gather_ps(Q3_F, idx, 4), vs));
            }
            for (; i < n; i++) wbuf[i] = Q3_F[pb[i] & 7] * sf;
            /* pass 2: dot */
            i = 0;
            for (; i + 8 <= n; i += 8)
                vsum = _mm256_fmadd_ps(_mm256_load_ps(wbuf+i), _mm256_loadu_ps(xg+i), vsum);
            for (; i < n; i++) vsum = _mm256_fmadd_ps(_mm256_set1_ps(wbuf[i]), _mm256_set1_ps(xg[i]), vsum);
        }
        y[r] = hsum256(vsum);
    }
}

/* AVX2 4-row parallel: shared x across 4 output rows */
static void q3_avx2_4row(float *y, const float *x, const uint8_t *pk,
                         const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const __m256i vm3 = _mm256_set1_epi32(7);

    int r = 0;
    for (; r + 3 < rows; r += 4) {
        __m256 vac[4];
        for (int k = 0; k < 4; k++) vac[k] = _mm256_setzero_ps();

        for (int g = 0; g < ngrp; g++) {
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            for (int row = 0; row < 4; row++) {
                uint8_t sb = sc[(r+row)*ngrp + g];
                float sf = (float)(sb - 32) * 0.01f;
                __m256 vs = _mm256_set1_ps(sf);
                const uint8_t *pb = pk + (size_t)(r+row)*in + (size_t)g*32;
                int i = 0;
                for (; i + 8 <= n; i += 8) {
                    __m128i b8 = _mm_loadl_epi64((const __m128i*)(pb + i));
                    __m256i idx = _mm256_and_si256(_mm256_cvtepu8_epi32(b8), vm3);
                    __m256 vw = _mm256_mul_ps(_mm256_i32gather_ps(Q3_F, idx, 4), vs);
                    vac[row] = _mm256_fmadd_ps(vw, _mm256_loadu_ps(xg + i), vac[row]);
                }
                for (; i < n; i++)
                    vac[row] = _mm256_fmadd_ps(_mm256_set1_ps(Q3_F[pb[i]&7]*sf),
                                               _mm256_set1_ps(xg[i]), vac[row]);
            }
        }
        for (int k = 0; k < 4; k++) y[r+k] = hsum256(vac[k]);
    }
    for (; r < rows; r++) {
        float acc = 0;
        for (int g = 0; g < ngrp; g++) {
            float sf = (float)(sc[r*ngrp+g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r*in + (size_t)g*32;
            const float *xg = x + (size_t)g*32;
            int n = in - g*32; if (n>32) n=32;
            for (int i = 0; i < n; i++) acc += Q3_F[pb[i]&7] * sf * xg[i];
        }
        y[r] = acc;
    }
}

/* AVX2 8-row parallel */
static void q3_avx2_8row(float *y, const float *x, const uint8_t *pk,
                         const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const __m256i vm3 = _mm256_set1_epi32(7);

    int r = 0;
    for (; r + 7 < rows; r += 8) {
        __m256 vac[8];
        for (int k = 0; k < 8; k++) vac[k] = _mm256_setzero_ps();

        for (int g = 0; g < ngrp; g++) {
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            for (int row = 0; row < 8; row++) {
                uint8_t sb = sc[(r+row)*ngrp + g];
                float sf = (float)(sb - 32) * 0.01f;
                __m256 vs = _mm256_set1_ps(sf);
                const uint8_t *pb = pk + (size_t)(r+row)*in + (size_t)g*32;
                int i = 0;
                for (; i + 8 <= n; i += 8) {
                    __m128i b8 = _mm_loadl_epi64((const __m128i*)(pb + i));
                    __m256i idx = _mm256_and_si256(_mm256_cvtepu8_epi32(b8), vm3);
                    __m256 vw = _mm256_mul_ps(_mm256_i32gather_ps(Q3_F, idx, 4), vs);
                    vac[row] = _mm256_fmadd_ps(vw, _mm256_loadu_ps(xg + i), vac[row]);
                }
                for (; i < n; i++)
                    vac[row] = _mm256_fmadd_ps(_mm256_set1_ps(Q3_F[pb[i]&7]*sf),
                                               _mm256_set1_ps(xg[i]), vac[row]);
            }
        }
        for (int k = 0; k < 8; k++) y[r+k] = hsum256(vac[k]);
    }
    for (; r < rows; r++) {
        float acc = 0;
        for (int g = 0; g < ngrp; g++) {
            float sf = (float)(sc[r*ngrp+g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r*in + (size_t)g*32;
            const float *xg = x + (size_t)g*32;
            int n = in - g*32; if (n>32) n=32;
            for (int i = 0; i < n; i++) acc += Q3_F[pb[i]&7] * sf * xg[i];
        }
        y[r] = acc;
    }
}

/* ============================================================ */
typedef void (*q3_fn_f)(float*, const float*, const uint8_t*, const uint8_t*, int, int);
typedef void (*q3_fn_d)(double*, const float*, const uint8_t*, const uint8_t*, int, int);

static double bench_f(q3_fn_f fn, int rows, int cols, int reps) {
    int ngrp = (cols+31)/32;
    float *x = malloc(sizeof(float)*cols);
    float *y = malloc(sizeof(float)*rows);
    uint8_t *pk = malloc((size_t)rows*cols);
    uint8_t *sc = malloc((size_t)rows*ngrp);
    if(!x||!y||!pk||!sc){printf("OOM\n");exit(1);}
    fill_float(x,cols,0xDEAD);
    fill_pseudorand(pk,(size_t)rows*cols,0xBEEF);
    for(size_t i=0;i<(size_t)rows*cols;i++) pk[i]&=7;
    fill_pseudorand(sc,(size_t)rows*ngrp,0xCAFE);
    for(size_t i=0;i<(size_t)rows*ngrp;i++) sc[i]&=0x7F;
    for(int i=0;i<3;i++) fn(y,x,pk,sc,cols,rows);
    double t0=now_s();
    for(int i=0;i<reps;i++) fn(y,x,pk,sc,cols,rows);
    double dt=now_s()-t0;
    volatile float sink=0; for(int i=0;i<rows;i++) sink+=y[i]; (void)sink;
    double mbps=(double)rows*cols*reps/dt/1e6;
    free(x);free(y);free(pk);free(sc);
    return mbps;
}
static double bench_d(q3_fn_d fn, int rows, int cols, int reps) {
    int ngrp = (cols+31)/32;
    float *x = malloc(sizeof(float)*cols);
    double *y = malloc(sizeof(double)*rows);
    uint8_t *pk = malloc((size_t)rows*cols);
    uint8_t *sc = malloc((size_t)rows*ngrp);
    if(!x||!y||!pk||!sc){printf("OOM\n");exit(1);}
    fill_float(x,cols,0xDEAD);
    fill_pseudorand(pk,(size_t)rows*cols,0xBEEF);
    for(size_t i=0;i<(size_t)rows*cols;i++) pk[i]&=7;
    fill_pseudorand(sc,(size_t)rows*ngrp,0xCAFE);
    for(size_t i=0;i<(size_t)rows*ngrp;i++) sc[i]&=0x7F;
    for(int i=0;i<3;i++) fn(y,x,pk,sc,cols,rows);
    double t0=now_s();
    for(int i=0;i<reps;i++) fn(y,x,pk,sc,cols,rows);
    double dt=now_s()-t0;
    volatile double sink=0; for(int i=0;i<rows;i++) sink+=y[i]; (void)sink;
    double mbps=(double)rows*cols*reps/dt/1e6;
    free(x);free(y);free(pk);free(sc);
    return mbps;
}

struct mt_job { q3_fn_f fn; float *y; const float *x; const uint8_t *pk; const uint8_t *sc; int in,r0,r1; };
static void *mt_worker(void *arg) {
    struct mt_job *j=arg;
    j->fn(j->y+j->r0, j->x, j->pk+(size_t)j->r0*j->in,
          j->sc+(size_t)j->r0*((j->in+31)/32), j->in, j->r1-j->r0);
    return NULL;
}

int main(int argc, char **argv) {
    int reps = argc > 1 ? atoi(argv[1]) : 200;
    int rows_base = 64, cols = 3584;
    int batch[] = {1, 8, 320};
    const char *bname[] = {"1 expert (64 rows)", "8 experts (512 rows)", "320 experts (20480 rows)"};

    printf("bench_q3_x86 — Q3 GEMV x86 AVX2 变体对比\n");
    printf("reps=%d, cols=%d, Q3: 8 values {-4..3}, group=32\n\n", reps, cols);

    for (int bi = 0; bi < 3; bi++) {
        int R = rows_base * batch[bi];
        printf("== %s (%d rows, pk=%.1f MB) ==\n", bname[bi], R, (double)R*cols/1e6);

        double r_scalar = bench_d(q3_scalar, R, cols, reps);
        double r_opt    = bench_f(q3_opt,    R, cols, reps);
        double r_v3     = bench_f(q3_v3,     R, cols, reps);
        double r_gather = bench_f(q3_avx2_gather, R, cols, reps);
        double r_2pass  = bench_f(q3_avx2_2pass,  R, cols, reps);
        double r_4row   = bench_f(q3_avx2_4row,   R, cols, reps);
        double r_8row   = bench_f(q3_avx2_8row,   R, cols, reps);

        printf("  scalar(d)  : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_scalar, r_scalar*2e-3, 1.0);
        printf("  opt(f32)   : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_opt, r_opt*2e-3, r_opt/r_scalar);
        printf("  v3(8way)   : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_v3, r_v3*2e-3, r_v3/r_scalar);
        printf("  avx2_gather: %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_gather, r_gather*2e-3, r_gather/r_scalar);
        printf("  avx2_2pass : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_2pass, r_2pass*2e-3, r_2pass/r_scalar);
        printf("  avx2_4row  : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_4row, r_4row*2e-3, r_4row/r_scalar);
        printf("  avx2_8row  : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
               r_8row, r_8row*2e-3, r_8row/r_scalar);

        if (batch[bi] > 1) {
            int nt = 8;
            int chunk = (R + nt - 1) / nt;
            int ngrp = (cols+31)/32;
            float *y_mt = malloc(sizeof(float)*R);
            float **tx = malloc(sizeof(float*)*nt);
            uint8_t *pk_all = malloc((size_t)R*cols);
            uint8_t *sc_all = malloc((size_t)R*ngrp);
            fill_pseudorand(pk_all,(size_t)R*cols,0xBEEF);
            for(size_t i=0;i<(size_t)R*cols;i++) pk_all[i]&=7;
            fill_pseudorand(sc_all,(size_t)R*ngrp,0xCAFE);
            for(size_t i=0;i<(size_t)R*ngrp;i++) sc_all[i]&=0x7F;
            for(int t=0;t<nt;t++){tx[t]=malloc(sizeof(float)*cols);fill_float(tx[t],cols,0xDEAD+t);}

            /* warmup */
            for(int w=0;w<2;w++){
                pthread_t tid[8]; struct mt_job job[8];
                for(int t=0;t<nt;t++){
                    job[t]=(struct mt_job){q3_avx2_gather,y_mt,tx[t],pk_all,sc_all,cols,t*chunk,(t+1)*chunk<R?(t+1)*chunk:R};
                    pthread_create(&tid[t],NULL,mt_worker,&job[t]);
                }
                for(int t=0;t<nt;t++) pthread_join(tid[t],NULL);
            }
            double t0=now_s();
            for(int i=0;i<reps;i++){
                pthread_t tid[8]; struct mt_job job[8];
                for(int t=0;t<nt;t++){
                    job[t]=(struct mt_job){q3_avx2_gather,y_mt,tx[t],pk_all,sc_all,cols,t*chunk,(t+1)*chunk<R?(t+1)*chunk:R};
                    pthread_create(&tid[t],NULL,mt_worker,&job[t]);
                }
                for(int t=0;t<nt;t++) pthread_join(tid[t],NULL);
            }
            double dt=now_s()-t0;
            double r_mt=(double)R*cols*reps/dt/1e6;
            printf("  gather x8t  : %8.1f MB/s  (%6.2f GFLOP/s)  x%.2f\n",
                   r_mt, r_mt*2e-3, r_mt/r_scalar);

            for(int t=0;t<nt;t++) free(tx[t]);
            free(tx);free(y_mt);free(pk_all);free(sc_all);
        }
        printf("\n");
    }

    printf("变体说明:\n");
    printf("  scalar(d)  = double 精度 baseline\n");
    printf("  opt(f32)   = float + 4-way unroll\n");
    printf("  v3(8way)   = float + 8-way unroll\n");
    printf("  avx2_gather= AVX2 _mm256_i32gather_ps 查表 + FMA\n");
    printf("  avx2_2pass = AVX2 解码→buffer + 纯FMA dot (ILP分离)\n");
    printf("  avx2_4row  = 4行并行, 共享x向量减少DRAM读\n");
    printf("  avx2_8row  = 8行并行, 更多共享但寄存器压力大\n");
    printf("\n关键指令: _mm256_i32gather_ps (Zen2: ~12c, Zen3/4: ~5c)\n");
    return 0;
}
