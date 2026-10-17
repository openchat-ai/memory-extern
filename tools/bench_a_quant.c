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

/* 分解 i8mm 每步开销: A 的量化 / A 的打包 / GEMM 本体 */
#include <arm_neon.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define QMAX 127.0f
static double now(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
  return t.tv_sec+1e-9*t.tv_nsec;}

/* 标量量化(与 i8gemm.c 中同名, 此处改名避免重复定义) */
static void quant_row_ref(const float*x,int n,int8_t*q,float*scale){
  float mx=0.f;
  for(int i=0;i<n;i++){float a=fabsf(x[i]);if(a>mx)mx=a;}
  float inv=QMAX/(mx>0.f?mx:1.f);
  for(int i=0;i<n;i++){int r=(int)(x[i]*inv+(x[i]>=0?0.5f:-0.5f));
    if(r>127)r=127; if(r<-127)r=-127; q[i]=(int8_t)r;}
  *scale=mx>0.f?mx/QMAX:1.f;
}
/* NEON 向量化版 */
static void quant_row_neon(const float*x,int n,int8_t*q,float*scale){
  float32x4_t vm=vdupq_n_f32(0.f);
  int i=0;
  for(;i+4<=n;i+=4) vm=vmaxq_f32(vm,vabsq_f32(vld1q_f32(x+i)));
  float m=vmaxvq_f32(vm);
  for(;i<n;i++){float a=fabsf(x[i]); if(a>m)m=a;}
  float inv=QMAX/(m>0.f?m:1.f);
  for(i=0;i+4<=n;i+=4){
    float32x4_t v=vmulq_n_f32(vld1q_f32(x+i),inv);
    uint32x4_t neg=vmvnq_u32(vcltq_f32(v,vdupq_n_f32(0.f)));
    float32x4_t rnd=vbslq_f32(neg,vdupq_n_f32(-0.5f),vdupq_n_f32(0.5f));
    int32x4_t iv=vcvtq_s32_f32(vaddq_f32(v,rnd));
    iv=vmaxq_s32(iv,vdupq_n_s32(-127));
    iv=vminq_s32(iv,vdupq_n_s32(127));
    int16x8_t h=vcombine_s16(vmovn_s32(iv),vmovn_s32(iv));
    int8x8_t  b=vqmovn_s16(h);
    memcpy(q+i, &b, 4);
  }
  for(;i<n;i++){int r=(int)(x[i]*inv+(x[i]>=0?0.5f:-0.5f));
    if(r>127)r=127; if(r<-127)r=-127; q[i]=(int8_t)r;}
  *scale=m>0.f?m/QMAX:1.f;
}
static void pack_a2(int M,int K8,const int8_t*Aq,int8_t*Ap){
  for(int m=0;m+1<M;m+=2)
    for(int kb=0;kb<K8/8;kb++){
      int8_t*d=Ap+((size_t)(m/2)*(K8/8)+kb)*16;
      memcpy(d,Aq+(size_t)m*K8+kb*8,8);
      memcpy(d+8,Aq+(size_t)(m+1)*K8+kb*8,8);
    }
}
static void quant_pack_fused(int M,int K,const float*A,int8_t*Ap,float*As){
  int K8=K&~7;
  for(int m=0;m+1<M;m+=2){
    quant_row_neon(A+(size_t)m*K,K,Ap+((size_t)(m/2)*(K8/8))*16+0,0); /* 暂不实现融合, 见下 */
    (void)As;
  }
}
int main(void){
  printf("%-22s %10s %10s %10s %10s %10s\n",
         "形状 M,K","量化(标量)","量化(NEON)","打包","合计","GEMM占比");
  printf("----------------------------------------------------------------\n");
  int sh[][2]={{256,192},{256,768},{256,3072},{256,12288}};
  for(int s=0;s<4;s++){
    int M=sh[s][0],K=sh[s][1]; int K8=K&~7;
    float*A=malloc((size_t)M*K*4); float*As=malloc((size_t)M*4);
    int8_t*Aq=malloc((size_t)M*K8); int8_t*Ap=malloc((size_t)(M/2)*(K8/8)*16);
    for(size_t i=0;i<(size_t)M*K;i++)A[i]=(float)(int)((i*37)%17)/8.f-1.f;
    /* 标量量化 */
    double t1=1e9; for(int r=0;r<20;r++){double t=now();
      for(int m=0;m<M;m++)quant_row_ref(A+(size_t)m*K,K,Aq+(size_t)m*K8,&As[m]);
      double d=now()-t; if(d<t1)t1=d;}
    /* NEON 量化 */
    double t2=1e9; for(int r=0;r<20;r++){double t=now();
      for(int m=0;m<M;m++)quant_row_neon(A+(size_t)m*K,K,Aq+(size_t)m*K8,&As[m]);
      double d=now()-t; if(d<t2)t2=d;}
    /* 打包 */
    double t3=1e9; for(int r=0;r<20;r++){double t=now();pack_a(M,K8,Aq,Ap);
      double d=now()-t; if(d<t3)t3=d;}
    /* GEMM 本体 (用已打包的 A, 1线程) */
    int N=768;
    float*Bs=malloc((size_t)N*4); int8_t*Bp=malloc((size_t)(N/2)*(K8/8)*16);
    for(int n=0;n<N;n++)Bs[n]=0.02f;
    for(size_t i=0;i<(size_t)(N/2)*(K8/8)*16;i++)Bp[i]=(int8_t)((i%17)-8);
    float*C=calloc((size_t)M*N,4);
    extern void i8mm_gemm(int,int,int,const int8_t*,const int8_t*,const float*,const float*,float*);
    i8mm_gemm(M,N,K8,Ap,Bp,As,Bs,C);
    double t4=1e9; for(int r=0;r<20;r++){double t=now();
      i8mm_gemm(M,N,K8,Ap,Bp,As,Bs,C); double d=now()-t; if(d<t4)t4=d;}
    double tot=t2+t3;
    printf("M%-4d K%-6d %9.3fms %9.3fms %9.3fms %9.3fms %9.1f%%\n",
           M,K,t1*1e3,t2*1e3,t3*1e3,tot*1e3,100*tot/(tot+t4));
    free(A);free(As);free(Aq);free(Ap);free(Bs);free(Bp);free(C);
  }
  (void)quant_pack_fused;
  return 0;
}
