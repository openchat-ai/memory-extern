/* i8mm (ARMv8.6) GEMM: C(M,N) = A(M,K) @ B(K,N), fp32 输入 / fp32 输出.
 *
 * SMMLA 语义(tools/bench_smmla.c 实测标定):
 *   vmmlaq_s32(acc, X, Y) 后:
 *     acc[0] += X[0..7] · Y[0..7]
 *     acc[1] += X[0..7] · Y[8..15]
 *     acc[2] += X[8..15]· Y[0..7]
 *     acc[3] += X[8..15]· Y[8..15]
 *
 *   故令 X = [A[m][k..k+7] | A[m+1][k..k+7]]
 *        Y = [B[k..k+7][n] | B[k..k+7][n+1]]
 *   则一条 SMMLA 恰好算出一个 2x2 输出块在 k 方向 8 个元素的贡献.
 *
 * 代价: A 与 B 都必须打包成 "2x8 交织" 布局 (否则两行/两列在内存里不相邻).
 * 量化: A 逐行、B 逐输出通道 对称 int8 量化, 算完乘回 scale.
 */
#include <pthread.h>
#include <arm_neon.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define QMAX 127.0f

/* 逐向量对称量化 */
static void quant_row(const float *x, int n, int8_t *q, float *scale) {
    float mx = 0.f;
    for (int i = 0; i < n; i++) { float a = fabsf(x[i]); if (a > mx) mx = a; }
    float s = mx / QMAX;
    if (s < 1e-12f) s = 1e-12f;
    float inv = QMAX / (mx > 0.f ? mx : 1.f);
    for (int i = 0; i < n; i++) {
        int r = (int)(x[i] * inv + (x[i] >= 0 ? 0.5f : -0.5f));
        if (r > 127) r = 127;
        if (r < -127) r = -127;
        q[i] = (int8_t)r;
    }
    *scale = mx > 0.f ? mx / QMAX : 1.f;
}

/* 打包 A(M,K) -> Ap((M/2)*(K/8)*16): 每 16 字节 = 两行 x 8 个 k */
__attribute__((target("i8mm")))
void pack_a(int M, int K8, const int8_t *Aq, int8_t *Ap) {
    for (int m = 0; m + 1 < M; m += 2)
        for (int kb = 0; kb < K8 / 8; kb++) {
            int8_t *d = Ap + ((size_t)(m / 2) * (K8 / 8) + kb) * 16;
            memcpy(d, Aq + (size_t)m * K8 + kb * 8, 8);
            memcpy(d + 8, Aq + (size_t)(m + 1) * K8 + kb * 8, 8);
        }
}

/* 打包 B: 先把 B(K,N) 量化并转置成 Bq(N,K), 再按 2x8 交织
 * Bp((N/2)*(K/8)*16): 每 16 字节 = 两列 x 8 个 k */
__attribute__((target("i8mm")))
void pack_b(int N, int K, int K8, const float *B, int8_t *Bp,
            float *Bs) {
    int8_t *Bq = malloc((size_t)N * K8);
    for (int n = 0; n < N; n++) {
        float mx = 0.f;
        for (int k = 0; k < K; k++) {
            float a = fabsf(B[(size_t)k * N + n]);
            if (a > mx) mx = a;
        }
        float inv = QMAX / (mx > 0.f ? mx : 1.f);
        Bs[n] = mx > 0.f ? mx / QMAX : 1.f;
        for (int k = 0; k < K8; k++) {
            float v = (k < K) ? B[(size_t)k * N + n] : 0.f;
            int r = (int)(v * inv + (v >= 0 ? 0.5f : -0.5f));
            if (r > 127) r = 127;
            if (r < -127) r = -127;
            Bq[(size_t)n * K8 + k] = (int8_t)r;
        }
    }
    for (int n = 0; n + 1 < N; n += 2)
        for (int kb = 0; kb < K8 / 8; kb++) {
            int8_t *d = Bp + ((size_t)(n / 2) * (K8 / 8) + kb) * 16;
            memcpy(d, Bq + (size_t)n * K8 + kb * 8, 8);
            memcpy(d + 8, Bq + (size_t)(n + 1) * K8 + kb * 8, 8);
        }
    free(Bq);
}

/* ---- 多线程: 按 (m 对 x n 对) 的输出块切分 ---- */
typedef struct {
    const int8_t *Ap, *Bp;
    const float *As, *Bs;
    float *C;
    int M, N, nkb;
    int mb0, mb1;      /* m 对区间 */
    int nb0, nb1;      /* n 对区间 */
} MT;

static MT g_mt;
static int g_nt;

__attribute__((target("i8mm")))
static void *mt_worker(void *arg) {
    long id = (long)arg;
    MT *w = &g_mt;
    int N = w->N;
    /* 只按 m 对切分: 每个线程负责一段 m 对, 内部遍历全部 n 对.
       (早期版本同时按 m 和 n 切分却让 tile 内又遍历 n, 导致 O(N^2) 冗余,
        实测慢 31~100 倍 —— 教训: 切分维度必须与 tile 循环维度一致) */
    int nmb = w->mb1 - w->mb0;
    int lo = w->mb0 + (int)((long)nmb * id / g_nt);
    int hi = w->mb0 + (int)((long)nmb * (id + 1) / g_nt);
    for (int mp = lo; mp < hi; mp++) {
        const int8_t *ap = w->Ap + (size_t)mp * w->nkb * 16;
        int m = mp * 2;
        for (int n = 0; n + 1 < N; n += 2) {
            const int8_t *bp = w->Bp + (size_t)(n / 2) * w->nkb * 16;
            int32x4_t acc = vdupq_n_s32(0);
            for (int kb = 0; kb < w->nkb; kb++) {
                uint8x16_t x = vreinterpretq_u8_s8(vld1q_s8(ap + kb * 16));
                uint8x16_t y = vreinterpretq_u8_s8(vld1q_s8(bp + kb * 16));
                acc = vmmlaq_s32(acc, x, y);
            }
            int32_t r[4];
            vst1q_s32(r, acc);
            w->C[(size_t)m * N + n]         = r[0] * w->As[m] * w->Bs[n];
            w->C[(size_t)m * N + n + 1]     = r[1] * w->As[m] * w->Bs[n + 1];
            w->C[(size_t)(m + 1) * N + n]   = r[2] * w->As[m + 1] * w->Bs[n];
            w->C[(size_t)(m + 1) * N + n+1] = r[3] * w->As[m + 1] * w->Bs[n + 1];
        }
    }
    return 0;
}

__attribute__((target("i8mm")))
void i8mm_gemm_mt(int M, int N, int K8, const int8_t *Ap, const int8_t *Bp,
                  const float *As, const float *Bs, float *C, int nt) {
    g_mt.Ap=Ap; g_mt.Bp=Bp; g_mt.As=As; g_mt.Bs=Bs; g_mt.C=C;
    g_mt.M=M; g_mt.N=N; g_mt.nkb=K8/8; g_mt.mb0=0; g_mt.mb1=M/2;
    g_nt = nt;
    pthread_t th[8];
    for (long t = 1; t < nt; t++) pthread_create(&th[t], 0, mt_worker, (void *)t);
    mt_worker((void *)0);
    for (long t = 1; t < nt; t++) pthread_join(th[t], 0);
}

/* GEMM 主循环 */
__attribute__((target("i8mm")))
void i8mm_gemm(int M, int N, int K8, const int8_t *Ap, const int8_t *Bp,
               const float *As, const float *Bs, float *C) {
    int nkb = K8 / 8;
    for (int m = 0; m + 1 < M; m += 2) {
        const int8_t *ap = Ap + (size_t)(m / 2) * nkb * 16;
        for (int n = 0; n + 1 < N; n += 2) {
            const int8_t *bp = Bp + (size_t)(n / 2) * nkb * 16;
            int32x4_t acc = vdupq_n_s32(0);
            for (int kb = 0; kb < nkb; kb++) {
                uint8x16_t x = vreinterpretq_u8_s8(vld1q_s8(ap + kb * 16));
                uint8x16_t y = vreinterpretq_u8_s8(vld1q_s8(bp + kb * 16));
                acc = vmmlaq_s32(acc, x, y);
            }
            int32_t r[4];
            vst1q_s32(r, acc);
            /* r[0]=C[m][n], r[1]=C[m][n+1], r[2]=C[m+1][n], r[3]=C[m+1][n+1] */
            C[(size_t)m * N + n]         = r[0] * As[m] * Bs[n];
            C[(size_t)m * N + n + 1]     = r[1] * As[m] * Bs[n + 1];
            C[(size_t)(m + 1) * N + n]   = r[2] * As[m + 1] * Bs[n];
            C[(size_t)(m + 1) * N + n+1] = r[3] * As[m + 1] * Bs[n + 1];
        }
    }
}

extern int shim_init(int,size_t);
extern int shim_dot(int,int,int,const float*,const float*,float*);
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec+1e-9*t.tv_nsec;}

int main(void){
  int sh[][3]={{256,192,192},{256,768,768},{256,768,3072},{256,768,12288}};
  shim_init(4,1600);
  printf("%-20s %11s %11s %11s %8s %8s %10s\n","形状 M,K,N","ggml fp32",
         "i8mm 1线程","i8mm 4线程","加速1T","加速4T","量化误差");
  printf("-----------------------------------------------------------------------\n");
  for(int si=0;si<4;si++){
    int M=sh[si][0],N=sh[si][1],K=sh[si][2];
    float*A=malloc((size_t)M*K*4),*B=malloc((size_t)K*N*4);
    float*C=calloc((size_t)M*N,4),*D=calloc((size_t)M*N,4);
    for(size_t i=0;i<(size_t)M*K;i++)A[i]=(float)(int)((i*37)%17)/8.f-1.f;
    for(size_t i=0;i<(size_t)K*N;i++)B[i]=(float)(int)((i*53)%19)/9.f-1.f;
    float*Bt=malloc((size_t)N*K*4);
    for(int k=0;k<K;k++)for(int n=0;n<N;n++)Bt[(size_t)n*K+k]=B[(size_t)k*N+n];
    shim_dot(M,N,K,A,Bt,D);
    double dg=1e9;
    for(int r=0;r<5;r++){double t=now();shim_dot(M,N,K,A,Bt,D);double d=now()-t;if(d<dg)dg=d;}
    int K8=K&~7,nkb=K8/8;
    float*Bs=malloc((size_t)N*4),*As=malloc((size_t)M*4);
    int8_t*Bp=malloc((size_t)(N/2)*nkb*16);
    int8_t*Aq=malloc((size_t)M*K8),*Ap=malloc((size_t)(M/2)*nkb*16);
    double t0=now(); pack_b(N,K,K8,B,Bp,Bs); double tpack=now()-t0;
    for(int m=0;m<M;m++) quant_row(A+(size_t)m*K,K,Aq+(size_t)m*K8,&As[m]);
    pack_a(M,K8,Aq,Ap);
    double d1=1e9,d4=1e9;
    for(int r=0;r<5;r++){double t=now();i8mm_gemm(M,N,K8,Ap,Bp,As,Bs,C);double d=now()-t;if(d<d1)d1=d;}
    for(int r=0;r<5;r++){double t=now();i8mm_gemm_mt(M,N,K8,Ap,Bp,As,Bs,C,4);double d=now()-t;if(d<d4)d4=d;}
    double e=0,n2=0;
    for(int i=0;i<M*N;i++){double dd=fabs(C[i]-D[i]);e+=dd*dd;n2+=(double)D[i]*D[i];}
    printf("M%-4d K%-5d N%-7d %10.2fms %10.2fms %10.2fms %7.2fx %7.2fx %10.2e\n",
           M,K,N,dg*1e3,d1*1e3,d4*1e3,dg/d1,dg/d4,sqrt(e/(n2+1e-30)));
    printf("        权重一次性打包 %.1f ms (仅加载时付一次)\n",tpack*1e3);
    free(A);free(B);free(C);free(D);free(Bt);free(Bs);free(As);
    free(Aq);free(Ap);free(Bp);
  }
  return 0;
}
