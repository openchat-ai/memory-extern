/* bench_q3.c — Q3 (3-bit) GEMV 全变体对比
 * 格式：每 weight 1 byte 低3位 (code 0..7 → val -4..3)
 * group=32, group_scale=byte(映射到 float)
 */
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <pthread.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Q3 值表: code 0..7 → val -4..3 */
static const float Q3_F[8] = {-4, -3, -2, -1, 0, 1, 2, 3};

/* fixture 生成 */
static void fill_pseudorand(uint8_t *buf, size_t n, unsigned seed) {
    for (size_t i = 0; i < n; i++)
        buf[i] = (uint8_t)((i * 40503u + seed) & 0xFF);
}
static void fill_float(float *buf, int n, unsigned seed) {
    for (int i = 0; i < n; i++)
        buf[i] = (float)((unsigned)(i * 2654435761u + seed) % 1000u) * 0.01f;
}

/* ============================================================
 * 变体定义
 * 输入: packed weight (1 byte/weight, 低3位), scales (1 byte/group),
 *        x (float32), group=32
 * ============================================================ */

/* A: scalar double (baseline) */
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

/* B: scalar float + 4-way */
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
            for (; i < n; i++)
                s0 += Q3_F[pb[i]&7] * xg[i];
            acc += (s0+s1+s2+s3) * s;
        }
        y[r] = acc;
    }
}

/* C: unpack to float buffer + dot */
static void q3_v2(float *y, const float *x, const uint8_t *pk,
                  const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    float wbuf[32];
    for (int r = 0; r < rows; r++) {
        float acc = 0;
        for (int g = 0; g < ngrp; g++) {
            float s = (float)(sc[r * ngrp + g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            for (int i = 0; i < n; i++)
                wbuf[i] = Q3_F[pb[i] & 7] * s;
            float s0=0,s1=0,s2=0,s3=0;
            int i = 0;
            for (; i+3 < n; i+=4) {
                s0 += wbuf[i]*xg[i]; s1 += wbuf[i+1]*xg[i+1];
                s2 += wbuf[i+2]*xg[i+2]; s3 += wbuf[i+3]*xg[i+3];
            }
            for (; i < n; i++) s0 += wbuf[i]*xg[i];
            acc += s0+s1+s2+s3;
        }
        y[r] = acc;
    }
}

/* D: flat table + 8-way (like v3) */
static float g_q3flat[8];
static int g_q3flat_init = 0;

static void q3_v3(float *y, const float *x, const uint8_t *pk,
                  const uint8_t *sc, int in, int rows) {
    if (!g_q3flat_init) { memcpy(g_q3flat, Q3_F, sizeof(Q3_F)); g_q3flat_init=1; }
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
                s0 += g_q3flat[pb[i]&7]*xg[i];     s1 += g_q3flat[pb[i+1]&7]*xg[i+1];
                s2 += g_q3flat[pb[i+2]&7]*xg[i+2]; s3 += g_q3flat[pb[i+3]&7]*xg[i+3];
                s4 += g_q3flat[pb[i+4]&7]*xg[i+4]; s5 += g_q3flat[pb[i+5]&7]*xg[i+5];
                s6 += g_q3flat[pb[i+6]&7]*xg[i+6]; s7 += g_q3flat[pb[i+7]&7]*xg[i+7];
            }
            for (; i+3 < n; i+=4) {
                s0 += g_q3flat[pb[i]&7]*xg[i];   s1 += g_q3flat[pb[i+1]&7]*xg[i+1];
                s2 += g_q3flat[pb[i+2]&7]*xg[i+2]; s3 += g_q3flat[pb[i+3]&7]*xg[i+3];
            }
            for (; i < n; i++) s0 += g_q3flat[pb[i]&7]*xg[i];
            acc += ((s0+s1)+(s2+s3)) + ((s4+s5)+(s6+s7));
            acc *= s;
        }
        y[r] = acc;
    }
}

/* E: NEON intrinsics (like v4) */
#if defined(__aarch64__)
static void q3_v4(float *y, const float *x, const uint8_t *pk,
                  const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const float *t = Q3_F;
    for (int r = 0; r < rows; r++) {
        float32x4_t vac0 = vdupq_n_f32(0), vac1 = vdupq_n_f32(0);
        float32x4_t vac2 = vdupq_n_f32(0), vac3 = vdupq_n_f32(0);
        for (int g = 0; g < ngrp; g++) {
            float scf = (float)(sc[r * ngrp + g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r * in + (size_t)g * 32;
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            int i = 0;
            for (; i+7 < n; i+=8) {
                float32x4_t vw0 = {t[pb[i]&7], t[pb[i+1]&7], t[pb[i+2]&7], t[pb[i+3]&7]};
                float32x4_t vw1 = {t[pb[i+4]&7], t[pb[i+5]&7], t[pb[i+6]&7], t[pb[i+7]&7]};
                vw0 = vmulq_n_f32(vw0, scf);
                vw1 = vmulq_n_f32(vw1, scf);
                vac0 = vfmaq_f32(vac0, vld1q_f32(xg+i), vw0);
                vac1 = vfmaq_f32(vac1, vld1q_f32(xg+i+4), vw1);
            }
            for (; i+3 < n; i+=4) {
                float32x4_t vw = {t[pb[i]&7], t[pb[i+1]&7], t[pb[i+2]&7], t[pb[i+3]&7]};
                vw = vmulq_n_f32(vw, scf);
                vac0 = vfmaq_f32(vac0, vld1q_f32(xg+i), vw);
            }
            for (; i < n; i++) {
                float32x4_t vs = vdupq_n_f32(t[pb[i]&7] * scf);
                vac0 = vfmaq_f32(vac0, vld1q_f32(xg+i), vs);
            }
        }
        float32x4_t vsum = vaddq_f32(vaddq_f32(vac0, vac1), vaddq_f32(vac2, vac3));
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r] = tmp[0]+tmp[1]+tmp[2]+tmp[3];
    }
}
#endif

/* F: 4-row parallel (like v8) */
#if defined(__aarch64__)
static void q3_v8(float *y, const float *x, const uint8_t *pk,
                  const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const float *t = Q3_F;
    int r = 0;
    for (; r+3 < rows; r+=4) {
        float32x4_t vac0=vdupq_n_f32(0),vac1=vdupq_n_f32(0);
        float32x4_t vac2=vdupq_n_f32(0),vac3=vdupq_n_f32(0);
        for (int g = 0; g < ngrp; g++) {
            const float *xg = x + (size_t)g * 32;
            int n = in - g * 32; if (n > 32) n = 32;
            for (int row = 0; row < 4; row++) {
                uint8_t sb = sc[(r+row)*ngrp+g];
                if (sb == 255) continue;
                float scf = (float)(sb - 32) * 0.01f;
                const uint8_t *pb = pk + (size_t)(r+row)*in + (size_t)g*32;
                float32x4_t *vac = (row==0)?&vac0:(row==1)?&vac1:(row==2)?&vac2:&vac3;
                int i = 0;
                for (; i+3 < n; i+=4) {
                    float32x4_t vw = {t[pb[i]&7]*scf, t[pb[i+1]&7]*scf, t[pb[i+2]&7]*scf, t[pb[i+3]&7]*scf};
                    *vac = vfmaq_f32(*vac, vld1q_f32(xg+i), vw);
                }
                for (; i < n; i++) {
                    float32x4_t vs = vdupq_n_f32(t[pb[i]&7] * scf);
                    *vac = vfmaq_f32(*vac, vld1q_f32(xg+i), vs);
                }
            }
        }
        float32x4_t vsum = vaddq_f32(vaddq_f32(vac0, vac1), vaddq_f32(vac2, vac3));
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r]=tmp[0]; y[r+1]=tmp[1]; y[r+2]=tmp[2]; y[r+3]=tmp[3];
    }
    for (; r < rows; r++) {
        float32x4_t vac0 = vdupq_n_f32(0);
        for (int g = 0; g < ngrp; g++) {
            float scf = (float)(sc[r*ngrp+g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r*in + (size_t)g*32;
            const float *xg = x + (size_t)g*32;
            int n = in - g*32; if (n>32) n=32;
            int i=0;
            for (; i+3<n; i+=4) {
                float32x4_t vw={t[pb[i]&7]*scf,t[pb[i+1]&7]*scf,t[pb[i+2]&7]*scf,t[pb[i+3]&7]*scf};
                vac0=vfmaq_f32(vac0,vld1q_f32(xg+i),vw);
            }
            for (;i<n;i++) {
                float32x4_t vs=vdupq_n_f32(t[pb[i]&7]*scf);
                vac0=vfmaq_f32(vac0,vld1q_f32(xg+i),vs);
            }
        }
        float tmp[4]; vst1q_f32(tmp, vac0);
        y[r]=tmp[0]+tmp[1]+tmp[2]+tmp[3];
    }
}
#endif

/* G: 2-pass dequant+dot (like v9) */
#if defined(__aarch64__)
static void q3_v9(float *y, const float *x, const uint8_t *pk,
                  const uint8_t *sc, int in, int rows) {
    const int ngrp = (in + 31) / 32;
    const float *t = Q3_F;
    float wbuf[32] __attribute__((aligned(16)));
    for (int r = 0; r < rows; r++) {
        float32x4_t vsum = vdupq_n_f32(0);
        for (int g = 0; g < ngrp; g++) {
            float scf = (float)(sc[r*ngrp+g] - 32) * 0.01f;
            const uint8_t *pb = pk + (size_t)r*in + (size_t)g*32;
            const float *xg = x + (size_t)g*32;
            int n = in - g*32; if (n>32) n=32;
            /* dequant */
            int i=0;
            for (; i+7<n; i+=8) {
                float32x4_t w0={t[pb[i]&7]*scf,t[pb[i+1]&7]*scf,t[pb[i+2]&7]*scf,t[pb[i+3]&7]*scf};
                float32x4_t w1={t[pb[i+4]&7]*scf,t[pb[i+5]&7]*scf,t[pb[i+6]&7]*scf,t[pb[i+7]&7]*scf};
                vst1q_f32(wbuf+i,w0); vst1q_f32(wbuf+i+4,w1);
            }
            for (; i+3<n; i+=4) {
                float32x4_t w={t[pb[i]&7]*scf,t[pb[i+1]&7]*scf,t[pb[i+2]&7]*scf,t[pb[i+3]&7]*scf};
                vst1q_f32(wbuf+i,w);
            }
            for (;i<n;i++) wbuf[i]=t[pb[i]&7]*scf;
            /* dot */
            i=0;
            for (;i+15<n;i+=16) {
                vsum=vfmaq_f32(vsum,vld1q_f32(xg+i),vld1q_f32(wbuf+i));
                vsum=vfmaq_f32(vsum,vld1q_f32(xg+i+4),vld1q_f32(wbuf+i+4));
                vsum=vfmaq_f32(vsum,vld1q_f32(xg+i+8),vld1q_f32(wbuf+i+8));
                vsum=vfmaq_f32(vsum,vld1q_f32(xg+i+12),vld1q_f32(wbuf+i+12));
            }
            for (;i+3<n;i+=4)
                vsum=vfmaq_f32(vsum,vld1q_f32(xg+i),vld1q_f32(wbuf+i));
            for (;i<n;i++)
                vsum=vfmaq_n_f32(vsum,vld1q_f32(xg+i),wbuf[i]);
        }
        float tmp[4]; vst1q_f32(tmp, vsum);
        y[r]=tmp[0]+tmp[1]+tmp[2]+tmp[3];
    }
}
#endif

/* ============ benchmark driver ============ */
typedef void (*q3_fn_f)(float*, const float*, const uint8_t*, const uint8_t*, int, int);
typedef void (*q3_fn_d)(double*, const float*, const uint8_t*, const uint8_t*, int, int);

static double bench_f(q3_fn_f fn, int rows, int cols, int reps) {
    int ngrp = (cols+31)/32;
    float *x=malloc(sizeof(float)*cols);
    float *y=malloc(sizeof(float)*rows);
    uint8_t *pk=malloc((size_t)rows*cols);
    uint8_t *sc=malloc((size_t)rows*ngrp);
    if(!x||!y||!pk||!sc){printf("OOM\n");exit(1);}
    fill_float(x,cols,0xDEAD);
    fill_pseudorand(pk,(size_t)rows*cols,0xBEEF);
    for(size_t i=0;i<(size_t)rows*cols;i++) pk[i]&=7;
    fill_pseudorand(sc,(size_t)rows*ngrp,0xCAFE);
    for(size_t i=0;i<(size_t)rows*ngrp;i++) sc[i]&=0x7F;
    for(int i=0;i<5;i++) fn(y,x,pk,sc,cols,rows);
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
    float *x=malloc(sizeof(float)*cols);
    double *y=malloc(sizeof(double)*rows);
    uint8_t *pk=malloc((size_t)rows*cols);
    uint8_t *sc=malloc((size_t)rows*ngrp);
    if(!x||!y||!pk||!sc){printf("OOM\n");exit(1);}
    fill_float(x,cols,0xDEAD);
    fill_pseudorand(pk,(size_t)rows*cols,0xBEEF);
    for(size_t i=0;i<(size_t)rows*cols;i++) pk[i]&=7;
    fill_pseudorand(sc,(size_t)rows*ngrp,0xCAFE);
    for(size_t i=0;i<(size_t)rows*ngrp;i++) sc[i]&=0x7F;
    for(int i=0;i<5;i++) fn(y,x,pk,sc,cols,rows);
    double t0=now_s();
    for(int i=0;i<reps;i++) fn(y,x,pk,sc,cols,rows);
    double dt=now_s()-t0;
    volatile double sink=0; for(int i=0;i<rows;i++) sink+=y[i]; (void)sink;
    double mbps=(double)rows*cols*reps/dt/1e6;
    free(x);free(y);free(pk);free(sc);
    return mbps;
}

/* MT */
struct mt_job { q3_fn_f fn; float *y; const float *x; const uint8_t *pk; const uint8_t *sc; int in,r0,r1; };
static void *mt_worker(void *arg) {
    struct mt_job *j=arg;
    j->fn(j->y+j->r0, j->x, j->pk+(size_t)j->r0*j->in, j->sc+(size_t)j->r0*((j->in+31)/32), j->in, j->r1-j->r0);
    return NULL;
}

int main(int argc, char **argv) {
    int reps = argc > 1 ? atoi(argv[1]) : 100;
    int rows = 64, cols = 3584;
    int batch[] = {1, 8, 320};
    const char *bname[] = {"1 expert (64 rows)", "8 experts (512 rows)", "320 experts (20480 rows)"};

    printf("bench_q3 — Q3 (3-bit) GEMV 全变体对比 (reps=%d, cols=%d)\n", reps, cols);
    printf("Q3: 8 values {-4..3}, group=32, DRAM wall ~6900 MB/s\n\n");

    for (int bi = 0; bi < 3; bi++) {
        int R = rows * batch[bi];
        printf("== %s (%d rows, pk=%.1f KB) ==\n", bname[bi], R, (double)R*cols/1024.0);

        double r_scalar = bench_d(q3_scalar, R, cols, reps);
        double r_opt    = bench_f(q3_opt,   R, cols, reps);
        double r_v2     = bench_f(q3_v2,    R, cols, reps);
        double r_v3     = bench_f(q3_v3,    R, cols, reps);
#if defined(__aarch64__)
        double r_v4     = bench_f(q3_v4,    R, cols, reps);
        double r_v8     = bench_f(q3_v8,    R, cols, reps);
        double r_v9     = bench_f(q3_v9,    R, cols, reps);
#endif

        printf("  A scalar(d): %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_scalar, r_scalar*2e-3, 1.0);
        printf("  B opt(f32) : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_opt, r_opt*2e-3, r_opt/r_scalar);
        printf("  C v2(unpk) : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_v2, r_v2*2e-3, r_v2/r_scalar);
        printf("  D v3(flat) : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_v3, r_v3*2e-3, r_v3/r_scalar);
#if defined(__aarch64__)
        printf("  E v4(neon) : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_v4, r_v4*2e-3, r_v4/r_scalar);
        printf("  F v8(4row) : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_v8, r_v8*2e-3, r_v8/r_scalar);
        printf("  G v9(2pass): %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
               r_v9, r_v9*2e-3, r_v9/r_scalar);
#endif

        if (batch[bi] > 1) {
#if defined(__aarch64__)
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

            /* opt x8t */
            for(int w=0;w<3;w++){
                pthread_t tid[8]; struct mt_job job[8];
                for(int t=0;t<nt;t++){
                    job[t]=(struct mt_job){q3_opt,y_mt,tx[t],pk_all,sc_all,cols,t*chunk,(t+1)*chunk<R?(t+1)*chunk:R};
                    pthread_create(&tid[t],NULL,mt_worker,&job[t]);
                }
                for(int t=0;t<nt;t++) pthread_join(tid[t],NULL);
            }
            double t0=now_s();
            for(int i=0;i<reps;i++){
                pthread_t tid[8]; struct mt_job job[8];
                for(int t=0;t<nt;t++){
                    job[t]=(struct mt_job){q3_opt,y_mt,tx[t],pk_all,sc_all,cols,t*chunk,(t+1)*chunk<R?(t+1)*chunk:R};
                    pthread_create(&tid[t],NULL,mt_worker,&job[t]);
                }
                for(int t=0;t<nt;t++) pthread_join(tid[t],NULL);
            }
            double dt=now_s()-t0;
            double r_mt_opt=(double)R*cols*reps/dt/1e6;
            printf("  opt x8t    : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
                   r_mt_opt, r_mt_opt*2e-3, r_mt_opt/r_scalar);

            /* v8 x8t */
            for(int w=0;w<3;w++){
                pthread_t tid[8]; struct mt_job job[8];
                for(int t=0;t<nt;t++){
                    job[t]=(struct mt_job){q3_v8,y_mt,tx[t],pk_all,sc_all,cols,t*chunk,(t+1)*chunk<R?(t+1)*chunk:R};
                    pthread_create(&tid[t],NULL,mt_worker,&job[t]);
                }
                for(int t=0;t<nt;t++) pthread_join(tid[t],NULL);
            }
            t0=now_s();
            for(int i=0;i<reps;i++){
                pthread_t tid[8]; struct mt_job job[8];
                for(int t=0;t<nt;t++){
                    job[t]=(struct mt_job){q3_v8,y_mt,tx[t],pk_all,sc_all,cols,t*chunk,(t+1)*chunk<R?(t+1)*chunk:R};
                    pthread_create(&tid[t],NULL,mt_worker,&job[t]);
                }
                for(int t=0;t<nt;t++) pthread_join(tid[t],NULL);
            }
            dt=now_s()-t0;
            double r_mt_v8=(double)R*cols*reps/dt/1e6;
            printf("  v8 x8t     : %7.1f MB/s  (%5.1f GFLOP/s)  x%.2f\n",
                   r_mt_v8, r_mt_v8*2e-3, r_mt_v8/r_scalar);

            for(int t=0;t<nt;t++) free(tx[t]);
            free(tx);free(y_mt);free(pk_all);free(sc_all);
#endif
        }
        printf("\n");
    }

    printf("解读:\n");
    printf("  - v4/v8 = NEON 向量化查表 + FMA (当前最优路径)\n");
    printf("  - v8 在多行场景通过共享x向量减少DRAM读取\n");
    printf("  - DRAM wall = 6900 MB/s, 真实推理还要看权重大小\n");
    return 0;
}
