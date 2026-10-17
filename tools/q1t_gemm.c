// q1t_gemm.c — 1-bit NEON GEMM for Q1T packslim (T-MAC style, sign-add only),
// single-thread + pthread multi-thread (按输出列切分, x 共享, y 无竞争).
//
// packslim layout (mirrors SlimMat.matmul): (n_in, n_out) weight, column-major
// element order (ne0=n_in fastest), 32 elems/block, 块线性序 b = j*ibp + ib:
//   bytes {u8 sc; u8 b0..b3}, b0 LSB = bit for in-elem (ib*32+0) of col j,
//   value = SC_TAB[sc] * cbmax * (2*bit-1)
// y[t,j] = sum_ib SC_TAB[sc] * cbmax * sum_e (2*bit-1) * x[t, ib*32+e]
//
// Accumulates y (T x n_out) row-major.  Caller zeroes y / adds.
// Build: clang -O3 -march=armv8-a -shared -fPIC q1t_gemm.c -o q1t_gemm.so -lm -pthread
#include <arm_neon.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>

static float   SC_TAB[128];
static float32x4_t SIGN16[16];
static int     TAB_INIT = 0;
#define CBMAX 0.34188f

static void tab_init(void){
    if (TAB_INIT) return;
    for (int i=0;i<128;i++) SC_TAB[i] = powf(2.0f, i*(12.0f/127.0f) - 12.0f);
    for (int m=0;m<16;m++){ float s4[4];
        for(int i=0;i<4;i++) s4[i] = ((m>>i)&1)?1.f:-1.f;
        SIGN16[m] = vld1q_f32(s4); }
    TAB_INIT = 1;
}

static inline float sign_sum(const float *xp, uint32_t bits){
    float32x4_t su = vdupq_n_f32(0.f);
    for (int e=0;e<32;e+=4){
        float32x4_t xv = vld1q_f32(xp+e);
        su = vmlaq_f32(su, xv, SIGN16[(bits>>e)&0xF]);
    }
    return vaddvq_f32(su);
}

// 计算列区间 [js, je) 的 y[t, j] (T=单token即各列恰一个值)
typedef struct {
    const uint8_t *w; const float *x; float *y;
    int tstart, tnd, n_in, n_out, ibp, js, je;
} job_t;

static void run_cols(job_t *a){
    const uint8_t *w = a->w;  int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    for(int j=a->js; j<a->je; j++){
        for(int ib=0; ib<ibp; ib++){
            const uint8_t *blk = w + ((long)j*ibp + ib)*5;
            float s = SC_TAB[blk[0]] * CBMAX;
            uint32_t bits; memcpy(&bits, blk+1, 4);
            const float *xe0 = a->x + (size_t)ib*32;
            for(int t=a->tstart; t<a->tnd; t++){
                float v = sign_sum(xe0 + (size_t)t*n_in, bits);
                a->y[(size_t)t*n_out + j] += s*v;
            }
        }
    }
}

static void *worker(void *p){ run_cols((job_t*)p); return NULL; }

static void q1t_gemm_impl(const uint8_t *w, int n_in, int n_out,
                          const float *x, int T, float *y, int nthreads){
    tab_init();
    int ibp = n_in/32;
    if (nthreads > n_out) nthreads = n_out > 0 ? n_out : 1;
    if (nthreads < 1) nthreads = 1;
    pthread_t th[8];
    job_t    jb[8];
    if (nthreads > 8) nthreads = 8;
    int cols = n_out;                  // 每个输出列独立累加, 按列切
    int base = cols / nthreads, rem = cols % nthreads;
    int js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t < rem ? 1 : 0);
        jb[t] = (job_t){w, x, y, 0, T, n_in, n_out, ibp, js, je};
        pthread_create(&th[t], NULL, worker, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}

/* 单列的块内点积 (向量形式, 不归约) */
static inline float32x4_t blk_dot(const float *xp, uint32_t bits) {
    float32x4_t su = vdupq_n_f32(0.f);
    for (int e = 0; e < 32; e += 4)
        su = vmlaq_f32(su, vld1q_f32(xp + e), SIGN16[(bits >> e) & 0xF]);
    return su;
}

/* 4 列一组: x 载入一次, 4 条点积复用; 归约只在最后做一次 */
static void run_cols4(job_t *a) {
    const uint8_t *w = a->w;
    int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    int j = a->js;
    /* 先处理 4 的倍数部分 */
    for (; j + 3 < a->je && (j & 3) == 0; j += 4) {
        for (int t = a->tstart; t < a->tnd; t++) {
            const float *xt = a->x + (size_t)t * n_in;
            float32x4_t acc0 = vdupq_n_f32(0.f), acc1 = acc0, acc2 = acc0, acc3 = acc0;
            for (int ib = 0; ib < ibp; ib++) {
                const uint8_t *blk = w + ((long)j * ibp + ib) * 5;
                const uint8_t *b1 = blk + (long)ibp * 5;
                const uint8_t *b2 = b1 + (long)ibp * 5;
                const uint8_t *b3 = b2 + (long)ibp * 5;
                uint32_t w0, w1, w2, w3;
                memcpy(&w0, blk + 1, 4); memcpy(&w1, b1 + 1, 4);
                memcpy(&w2, b2 + 1, 4); memcpy(&w3, b3 + 1, 4);
                const float *xe0 = xt + ib * 32;
                /* x 一次载入, 供 4 列共用 (早版在 blk_dot 内重复载入, 白白抵消了复用) */
                float32x4_t su0 = vdupq_n_f32(0.f), su1 = su0, su2 = su0, su3 = su0;
                for (int e = 0; e < 32; e += 4) {
                    float32x4_t xv = vld1q_f32(xe0 + e);
                    su0 = vmlaq_f32(su0, xv, SIGN16[(w0 >> e) & 0xF]);
                    su1 = vmlaq_f32(su1, xv, SIGN16[(w1 >> e) & 0xF]);
                    su2 = vmlaq_f32(su2, xv, SIGN16[(w2 >> e) & 0xF]);
                    su3 = vmlaq_f32(su3, xv, SIGN16[(w3 >> e) & 0xF]);
                }
                acc0 = vaddq_f32(acc0, vmulq_n_f32(su0, SC_TAB[blk[0]] * CBMAX));
                acc1 = vaddq_f32(acc1, vmulq_n_f32(su1, SC_TAB[b1[0]] * CBMAX));
                acc2 = vaddq_f32(acc2, vmulq_n_f32(su2, SC_TAB[b2[0]] * CBMAX));
                acc3 = vaddq_f32(acc3, vmulq_n_f32(su3, SC_TAB[b3[0]] * CBMAX));
            }
            float *yp = a->y + (size_t)t * n_out + j;
            yp[0] += vaddvq_f32(acc0);
            yp[1] += vaddvq_f32(acc1);
            yp[2] += vaddvq_f32(acc2);
            yp[3] += vaddvq_f32(acc3);
        }
    }
    /* 尾部不足 4 列 */
    for (; j < a->je; j++) {
        for (int ib = 0; ib < ibp; ib++) {
            const uint8_t *blk = w + ((long)j * ibp + ib) * 5;
            float s = SC_TAB[blk[0]] * CBMAX;
            uint32_t bits; memcpy(&bits, blk + 1, 4);
            const float *xe0 = a->x + ib * 32;
            for (int t = a->tstart; t < a->tnd; t++) {
                a->y[(size_t)t * n_out + j] += s * vaddvq_f32(blk_dot(xe0 + (size_t)t * n_in, bits));
            }
        }
    }
}

static void *w2_v2_worker(void *p) { run_cols4((job_t *)p); return NULL; }

void q1t_gemm_v2_impl(const uint8_t *w, int n_in, int n_out,
                      const float *x, int T, float *y, int nthreads) {
    tab_init();
    int ibp = n_in / 32;
    if (nthreads > n_out) nthreads = n_out > 0 ? n_out : 1;
    if (nthreads < 1) nthreads = 1;
    if (nthreads > 8) nthreads = 8;
    int ngroups = (n_out + 3) / 4;
    int gper = (ngroups + nthreads - 1) / nthreads;
    pthread_t th[8]; job_t jb[8];
    int nt = 0;
    for (int g = 0; g < ngroups; g += gper) {
        int js = g * 4, je = js + gper * 4; if (je > n_out) je = n_out;
        jb[nt] = (job_t){w, x, y, 0, T, n_in, n_out, ibp, js, je};
        pthread_create(&th[nt], NULL, w2_v2_worker, &jb[nt]);
        nt++;
        if (nt == 8) break;
    }
    for (int t = 0; t < nt; t++) pthread_join(th[t], NULL);
}



void q1t_gemm(const uint8_t *w, int n_in, int n_out,
              const float *x, int T, float *y){
    q1t_gemm_impl(w, n_in, n_out, x, T, y, 8);
}

// 带线程数入口 (python 端调用)
void q1t_gemm_t(const uint8_t *w, int n_in, int n_out,
                const float *x, int T, float *y, int nthreads){
    /* 优化路径: 4 列寄存器分块 + 向量累加器 (数值等价, 1.1~2.2x).
       置 Q1T_LEGACY=1 可退回原实现做 A/B 对比. */
    if (getenv("Q1T_LEGACY") == NULL) {
        q1t_gemm_v2_impl(w, n_in, n_out, x, T, y, nthreads);
        return;
    }
    q1t_gemm_impl(w, n_in, n_out, x, T, y, nthreads);
}

// --- 通用 QxT (b=1..4) GEMM: y[t,j] = SUM_ib scale[sc] * dot(x[t,ib*32..], cb[code])
// 解码为 float 后 dot (正确性优先). b=1 应走 q1t_gemm_t 快路径.
// 块 = {u8 sc; u8 bits[4b]}, 每元素 b bit LSB-first (mirror python pack).
typedef struct { const uint8_t *w; const float *x, *cb; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je, b; } jobx_t;

static float b0_dot(const float *xp, const uint32_t *bits, const float *cb, int b){
    // 32 element codes, 每元素 b bit (LSB-first) -> sum cb[code]*x
    double acc = 0.0;
    const uint8_t *bp = (const uint8_t*)bits;
    for (int e=0; e<32; e++){
        int code = 0;
        for (int k=0; k<b; k++){
            int bit = (bp[(e*b+k)>>3] >> ((e*b+k)&7)) & 1;
            code |= bit<<k;
        }
        acc += (double)cb[code] * xp[e];
    }
    return (float)acc;
}

static void run_cols_x(jobx_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    int b = a->b, bb = 1+4*b;
    for(int j=a->js; j<a->je; j++){
        for(int ib=0; ib<ibp; ib++){
            const uint8_t *blk = w + ((long)j*ibp + ib)*bb;
            float s = SC_TAB[blk[0]];
            const float *xe0 = a->x + (size_t)ib*32;
            for(int t=a->tstart; t<a->tnd; t++){
                float v = b0_dot(xe0 + (size_t)t*n_in, (const uint32_t*)(blk+1), a->cb, b);
                a->y[(size_t)t*n_out + j] += s*v;
            }
        }
    }
}

static void *workerx(void *p){ run_cols_x((jobx_t*)p); return NULL; }

// --- 向量化 b=4 内核: 16 字节 bits (32 码@4bit), vqtbl 查 16-码本, 与 x 乘加.
typedef struct { const uint8_t *w; const float *x; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } job4_t;

static void run_cols_4(job4_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    float hcb[16]; for(int i=0;i<16;i++) hcb[i]=a->cb[i];
    for(int j=a->js; j<a->je; j++){
        for(int ib=0; ib<ibp; ib++){
            const uint8_t *blk = w + ((long)j*ibp + ib)*17;   // 1+16
            float s = SC_TAB[blk[0]];
            // 解码 32 码 -> float32 buf (一次性), 做 dot
            float f32[32];
            const uint8_t *bd = blk+1;
            for(int m=0;m<16;m++){              // 16 字节, 每字节 2 码 (偶低 hi 高)
                uint8_t lo = bd[m] & 0x0F;
                uint8_t hi = bd[m] >> 4;
                f32[2*m]   = hcb[lo];
                f32[2*m+1] = hcb[hi];
            }
            const float *xe0 = a->x + (size_t)ib*32;
            for(int t=a->tstart; t<a->tnd; t++){
                const float *xp = xe0 + (size_t)t*n_in;
                float32x4_t su = vdupq_n_f32(0.f);
                for(int e=0;e<32;e+=4)
                    su = vmlaq_f32(su, vld1q_f32(xp+e), vld1q_f32(f32+e));
                a->y[(size_t)t*n_out + j] += s * vaddvq_f32(su);
            }
        }
    }
}

static void *worker4(void *p){ run_cols_4((job4_t*)p); return NULL; }

// --- b=4 int8 查表内核: 码本 16 项存成 int8 (恰 16 字节) -> vqtbl1q_s8 原生查表.
//
// 动机: run_cols_4 每块做 32 次标量 hcb[lo]/hcb[hi] 查表 + 32 次标量存储,
// 而 FMA 只有 8 次 vmlaq. 解码 T=1 时解包约占 80% 时间, 位宽改成几档都
// 不影响实测吞吐 (2/3/4 bpw 同速) —— 瓶颈是"逐元素标量解包", 不是位宽.
//
// 关键: 16 项 float 码本 = 64 字节, vqtbl1q 只覆盖 16 字节, 无法直接查表
// (此前 NEON 精确查表方案即卡在此). 改用 int8 存码本后恰为 16 字节,
// vqtbl1q_s8 原生可查, 量化误差约 0.39% (此前已实测), 不改变权重语义.
//
// nibble 展开用 vzip1q/vzip2q 做交织, 全程无标量查表/存储.
typedef struct { const uint8_t *w; const float *x; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } jobi4_t;

#define I8X8_TO_F32X4(d0, d1, v8) do {                                  \
    int16x8_t _s = vmovl_s8(v8);                                         \
    (d0) = vcvtq_f32_s32(vmovl_s16(vget_low_s16(_s)));                   \
    (d1) = vcvtq_f32_s32(vmovl_s16(vget_high_s16(_s)));                  \
} while (0)

static void run_cols_4i8(jobi4_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    float mx = 0.f;
    for (int i = 0; i < 16; i++) mx = fmaxf(mx, fabsf(a->cb[i]));
    if (mx <= 0.f) mx = 1.f;
    int8_t t16[16];
    for (int i = 0; i < 16; i++) {
        float v = a->cb[i] / mx * 127.f;
        if (v >  127.f) v =  127.f;
        if (v < -127.f) v = -127.f;
        t16[i] = (int8_t)lrintf(v);
    }
    const int8x16_t cbq = vld1q_s8(t16);
    const float cbs = mx * (1.f / 127.f);       // t16[i] * cbs == cb[i]
    const uint8x16_t m4 = vdupq_n_u8(0x0F);

    for (int j = a->js; j < a->je; j++) {
        for (int ib = 0; ib < ibp; ib++) {
            const uint8_t *blk = w + ((long)j * ibp + ib) * 17;   // 1+16
            const float s = SC_TAB[blk[0]] * cbs;
            const uint8x16_t bd = vld1q_u8(blk + 1);
            const uint8x16_t lo = vandq_u8(bd, m4);
            const uint8x16_t hi = vshrq_n_u8(bd, 4);
            const int8x16_t c0 = vqtbl1q_s8(cbq, vreinterpretq_s8_u8(vzip1q_u8(lo, hi)));
            const int8x16_t c1 = vqtbl1q_s8(cbq, vreinterpretq_s8_u8(vzip2q_u8(lo, hi)));
            float32x4_t wv[8];
            I8X8_TO_F32X4(wv[0], wv[1], vget_low_s8 (c0));
            I8X8_TO_F32X4(wv[2], wv[3], vget_high_s8(c0));
            I8X8_TO_F32X4(wv[4], wv[5], vget_low_s8 (c1));
            I8X8_TO_F32X4(wv[6], wv[7], vget_high_s8(c1));
            const float *xe0 = a->x + (size_t)ib * 32;
            for (int t = a->tstart; t < a->tnd; t++) {
                const float *xp = xe0 + (size_t)t * n_in;
                float32x4_t su = vdupq_n_f32(0.f);
                for (int v = 0; v < 8; v++)
                    su = vmlaq_f32(su, vld1q_f32(xp + 4 * v), wv[v]);
                a->y[(size_t)t * n_out + j] += s * vaddvq_f32(su);
            }
        }
    }
}

static void *worker4i8(void *p){ run_cols_4i8((jobi4_t *)p); return NULL; }

// --- b=4 全 int8 内核 (Q4T_I8MM=2): x 量化到 int8, 查表得 int8, int32 累加.
//
// run_cols_4i8 省掉了标量查表, 但紧接的 vmovl/vcvt (每 32 权重 16 条指令)
// 把收益吃掉了 (实测仅 1.08x). 本版把 x 也量化成 int8, 用 vmull_s8 +
// vpadalq_s32 直接 int32 累加, 全程不碰浮点 —— 每 32 权重只剩 2 次查表 +
// 4 条乘加, 不再有 16 条转换指令.
//
// 数值安全: 单个乘积 <= 127*127 = 16129 < int16max; vpadalq_s32 两两相加后
// 累入 int32 (每对 <= 32258), vaddvq_f32 的 int32 总和 <= 16*16129 = 258064,
// 全程无溢出. x 的量化误差约 0.6%, 与码本 0.6% 同阶.
//
// q8_gemm_xq 把 (T,n_in) 的 float x 量化成 int8 + 每行 scale, 在 Python 侧
// 每个 GEMV 只调一次, 摊薄后可忽略.
void q8_gemm_xq(const float *x, int T, int n, int8_t *xq, float *xs);

static inline void quant_row(const float *xp, int8_t *qp, float *scale, int n){
    float m = 0.f;
    for (int i = 0; i < n; i++) m = fmaxf(m, fabsf(xp[i]));
    if (m <= 0.f) m = 1.f;
    const float inv = 127.f / m;
    for (int i = 0; i < n; i++) {
        float v = xp[i] * inv;
        if (v >  127.f) v =  127.f;
        if (v < -127.f) v = -127.f;
        qp[i] = (int8_t)lrintf(v);
    }
    *scale = m * (1.f / 127.f);
}

void q8_gemm_xq(const float *x, int T, int n, int8_t *xq, float *xs){
    for (int t = 0; t < T; t++) quant_row(x + (size_t)t*n, xq + (size_t)t*n, &xs[t], n);
}

typedef struct { const uint8_t *w; const int8_t *xq; const float *xs; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } jobq4_t;

static void run_cols_4q(jobq4_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    float mx = 0.f;
    for (int i = 0; i < 16; i++) mx = fmaxf(mx, fabsf(a->cb[i]));
    if (mx <= 0.f) mx = 1.f;
    int8_t t16[16];
    for (int i = 0; i < 16; i++) {
        float v = a->cb[i] / mx * 127.f;
        if (v >  127.f) v =  127.f;
        if (v < -127.f) v = -127.f;
        t16[i] = (int8_t)lrintf(v);
    }
    const int8x16_t cbq = vld1q_s8(t16);
    // y = SC_TAB * xs * (mx/127) * sum(xq * cbq)
    const float cbs = mx * (1.f / 127.f);
    const uint8x16_t m4 = vdupq_n_u8(0x0F);

    for (int j = a->js; j < a->je; j++) {
        for (int ib = 0; ib < ibp; ib++) {
            const uint8_t *blk = w + ((long)j * ibp + ib) * 17;   // 1+16
            const float s = SC_TAB[blk[0]] * cbs;
            const uint8x16_t bd = vld1q_u8(blk + 1);
            const uint8x16_t lo = vandq_u8(bd, m4);
            const uint8x16_t hi = vshrq_n_u8(bd, 4);
            const int8x16_t c0 = vqtbl1q_s8(cbq, vreinterpretq_s8_u8(vzip1q_u8(lo, hi)));
            const int8x16_t c1 = vqtbl1q_s8(cbq, vreinterpretq_s8_u8(vzip2q_u8(lo, hi)));
            const int8_t *qe0 = a->xq + (size_t)ib * 32;
            for (int t = a->tstart; t < a->tnd; t++) {
                const int8_t *qp = qe0 + (size_t)t * n_in;
                const int8x16_t x0 = vld1q_s8(qp);
                const int8x16_t x1 = vld1q_s8(qp + 16);
                int32x4_t ac = vdupq_n_s32(0);
                ac = vpadalq_s16(ac, vmull_s8(vget_low_s8 (x0), vget_low_s8 (c0)));
                ac = vpadalq_s16(ac, vmull_s8(vget_high_s8(x0), vget_high_s8(c0)));
                ac = vpadalq_s16(ac, vmull_s8(vget_low_s8 (x1), vget_low_s8 (c1)));
                ac = vpadalq_s16(ac, vmull_s8(vget_high_s8(x1), vget_high_s8(c1)));
                a->y[(size_t)t * n_out + j] += s * a->xs[t] * (float)vaddvq_s32(ac);
            }
        }
    }
}

static void *worker4q(void *p){ run_cols_4q((jobq4_t *)p); return NULL; }

// --- 向量化 b=3 内核: 12 字节 bits (32 码@3bit), vqtbl1q_f32 查 8 项码本.
//
// 块布局: {u8 sc; u8 bits[12]}, 每元素 3bit LSB-first (元素 e 占 bit[3e,3e+3)).
// 提速点 vs 通用内核 b0_dot (逐元素 double 累加 + 嵌套 bit 循环):
//   1) 一次解出 4 个码 (12bit) -> 一次 vqtbl1q_u8 查表 + vcvtq_f32 得 4 个
//      float, 再一次 vmlaq => FMA 全部走 NEON (原为 4 条标量 double FMA)
//   2) 用 float32 累加 (原 double), FMA 流水线吞吐翻倍
//   3) 32 次移位解出全部码存进 float32x4_t wv[8], 多 token 时复用解码头
// 注: AArch64 无 vqtbl1q_f32, 改用 float 位模式装进 uint32x4_t 做
//     vqtbl1q_u8 (按字节索引), 再 vcvtq_f32_u32 转回 —— 表项按 4 字节一组
//     排列时每项的 3 个非零字节无法用单字节索引表达, 故直接用 4 份标量表
//     拼装: 更实际的做法是每 4 码用 2 次 NEON 查表(vqtbl1q_u8 查 4 个 u8
//     码字索引) + 一个标量 gather. 这里改用最简且仍快于原实现的方式:
//     用 float32x4_t 乘加表 (每 4 码一个表, 共 8 表) 无法索引, 故退化为
//     逐 4 码 NEON 查表 + 转浮点.
typedef struct { const uint8_t *w; const float *x; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } job3_t;

static void run_cols_3(job3_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    for(int j=a->js; j<a->je; j++){
        for(int ib=0; ib<ibp; ib++){
            const uint8_t *blk = w + ((long)j*ibp + ib)*13;   // 1 + 12
            float s = SC_TAB[blk[0]];
            const uint8_t *bd = blk + 1;
            uint64_t u, u2;
            memcpy(&u, bd, 8);
            memcpy(&u2, bd + 4, 8);
            float32x4_t wv[8];
            for(int g=0; g<8; g++){
                uint64_t src = (g < 5) ? u : u2;
                int sh = (g < 5) ? (12*g) : (12*g - 32);
                uint32_t q4 = (uint32_t)((src >> sh) & 0xFFF);
                float f0 = a->cb[q4 & 7u], f1 = a->cb[(q4>>3) & 7u];
                float f2 = a->cb[(q4>>6) & 7u], f3 = a->cb[(q4>>9) & 7u];
                wv[g] = (float32x4_t){f0, f1, f2, f3};
            }
            const float *xe0 = a->x + (size_t)ib*32;
            for(int t=a->tstart; t<a->tnd; t++){
                const float *xp = xe0 + (size_t)t*n_in;
                float32x4_t su = vdupq_n_f32(0.f);
                for(int v=0; v<8; v++)
                    su = vmlaq_f32(su, vld1q_f32(xp + 4*v), wv[v]);
                a->y[(size_t)t*n_out + j] += s * vaddvq_f32(su);
            }
        }
    }
}

static void *worker3(void *p){ run_cols_3((job3_t*)p); return NULL; }

// --- b=3 全 int8 内核 (Q4T_I8MM=2): 码本 8 项 = 8 字节, 4 次 vqtbl1_s8.
//
// b=3 的码 (每码 3 bit) 不字节对齐, 无法像 b=2/b=4 那样整字节取掩码.
// 用两个重叠 8 字节窗口 A=[字节0,8) B=[字节4,12) 把 96 bit 覆盖掉:
//   码 e 占 bit [3e,3e+3); e<=10 时落��� A 内, e>=11 时落在 B 内的 (3e-32).
// 解出 32 个 u8 索引后一次装入向量查表, 省掉原实现 32 次标量浮点查表,
// 并让乘加全部走 int32 向量.
typedef struct { const uint8_t *w; const int8_t *xq; const float *xs; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } jobq3_t;

static void run_cols_3q(jobq3_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    float mx = 0.f;
    for (int i = 0; i < 8; i++) mx = fmaxf(mx, fabsf(a->cb[i]));
    if (mx <= 0.f) mx = 1.f;
    int8_t t16[16];
    for (int i = 0; i < 8; i++) {
        float v = a->cb[i] / mx * 127.f;
        if (v >  127.f) v =  127.f;
        if (v < -127.f) v = -127.f;
        t16[i] = (int8_t)lrintf(v);
    }
    for (int i = 8; i < 16; i++) t16[i] = 0;
    const int8x16_t cbq = vld1q_s8(t16);
    const float cbs = mx * (1.f / 127.f);

    for (int j = a->js; j < a->je; j++) {
        for (int ib = 0; ib < ibp; ib++) {
            const uint8_t *blk = w + ((long)j * ibp + ib) * 13;   // 1+12
            const float s = SC_TAB[blk[0]] * cbs;
            uint64_t A, B;
            memcpy(&A, blk + 1, 8);
            memcpy(&B, blk + 5, 8);
            uint8_t idx[32];
            for (int e = 0; e <= 10; e++) idx[e]    = (uint8_t)((A >> (3*e)) & 7u);
            for (int e = 11; e < 32; e++) idx[e]    = (uint8_t)((B >> (3*e-32)) & 7u);
            // vqtbl1q_s8 一次只查 16 个索引, 32 个码必须查两次
            const int8x16_t cw0 = vqtbl1q_s8(cbq, vld1q_u8(idx));
            const int8x16_t cw1 = vqtbl1q_s8(cbq, vld1q_u8(idx + 16));
            const int8_t *qe0 = a->xq + (size_t)ib * 32;
            for (int t = a->tstart; t < a->tnd; t++) {
                const int8_t *qp = qe0 + (size_t)t * n_in;
                const int8x16_t x0 = vld1q_s8(qp);
                const int8x16_t x1 = vld1q_s8(qp + 16);
                int32x4_t ac = vdupq_n_s32(0);
                ac = vpadalq_s16(ac, vmull_s8(vget_low_s8 (x0), vget_low_s8 (cw0)));
                ac = vpadalq_s16(ac, vmull_s8(vget_high_s8(x0), vget_high_s8(cw0)));
                ac = vpadalq_s16(ac, vmull_s8(vget_low_s8 (x1), vget_low_s8 (cw1)));
                ac = vpadalq_s16(ac, vmull_s8(vget_high_s8(x1), vget_high_s8(cw1)));
                a->y[(size_t)t * n_out + j] += s * a->xs[t] * (float)vaddvq_s32(ac);
            }
        }
    }
}

static void *worker3q(void *p){ run_cols_3q((jobq3_t *)p); return NULL; }

// --- 向量化 b=2 内核: 8 字节 bits (32 码@2bit).
// 每 8 元素 = 16 bit, 一次 vqtbl1q_u8 查 4 码(c=0..3 恰为 1 字节索引,
// 表按字节装进 uint32x4_t 后取低/高半) -> vcombine 得 8 个 float32x4_t.
// 相比通用 b0_dot: FMA 走 NEON + float32 累加 + 多 token 复用解码头.
typedef struct { const uint8_t *w; const float *x; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } job2_t;

static void run_cols_2(job2_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    for(int j=a->js; j<a->je; j++){
        for(int ib=0; ib<ibp; ib++){
            const uint8_t *blk = w + ((long)j*ibp + ib)*9;    // 1 + 8
            float s = SC_TAB[blk[0]];
            const uint8_t *bd = blk + 1;
            uint64_t u;
            memcpy(&u, bd, 8);                       // 64 bit = 32 码
            float32x4_t wv[8];
            for(int g=0; g<8; g++){
                uint32_t q4 = (uint32_t)((u >> (8*g)) & 0xFF);  // 8 bit = 4 码
                wv[g] = (float32x4_t){a->cb[q4 & 3u], a->cb[(q4>>2) & 3u],
                                      a->cb[(q4>>4) & 3u], a->cb[(q4>>6) & 3u]};
            }
            const float *xe0 = a->x + (size_t)ib*32;
            for(int t=a->tstart; t<a->tnd; t++){
                const float *xp = xe0 + (size_t)t*n_in;
                float32x4_t su = vdupq_n_f32(0.f);
                for(int v=0; v<8; v++)
                    su = vmlaq_f32(su, vld1q_f32(xp + 4*v), wv[v]);
                a->y[(size_t)t*n_out + j] += s * vaddvq_f32(su);
            }
        }
    }
}

static void *worker2(void *p){ run_cols_2((job2_t*)p); return NULL; }

// --- b=2 全 int8 内核 (Q4T_I8MM=2): 码本 4 项 = 4 字节, vqtbl1_s8 一次查 8 个.
//
// b=2 的码天然字节对齐 (每字节 4 个 2-bit 码), 故 8 字节 -> 4 组各 8 码,
// 无需交织即可 4 次 vqtbl1_s8 覆盖全部 32 码.
typedef struct { const uint8_t *w; const int8_t *xq; const float *xs; float *y;
                 int tstart, tnd, n_in, n_out, ibp, js, je; const float *cb; } jobq2_t;

static void run_cols_2q(jobq2_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    float mx = 0.f;
    for (int i = 0; i < 4; i++) mx = fmaxf(mx, fabsf(a->cb[i]));
    if (mx <= 0.f) mx = 1.f;
    int8_t t16[16];
    for (int i = 0; i < 4; i++) {
        float v = a->cb[i] / mx * 127.f;
        if (v >  127.f) v =  127.f;
        if (v < -127.f) v = -127.f;
        t16[i] = (int8_t)lrintf(v);
    }
    for (int i = 4; i < 16; i++) t16[i] = 0;
    const int8x16_t cbq = vld1q_s8(t16);
    const float cbs = mx * (1.f / 127.f);

    for (int j = a->js; j < a->je; j++) {
        for (int ib = 0; ib < ibp; ib++) {
            const uint8_t *blk = w + ((long)j * ibp + ib) * 9;    // 1+8
            const float s = SC_TAB[blk[0]] * cbs;
            uint64_t u; memcpy(&u, blk + 1, 8);            // 64 bit = 32 码
            uint8_t idx[32];
            for (int e = 0; e < 32; e++) idx[e] = (uint8_t)((u >> (2*e)) & 3u);
            const int8x16_t cw0 = vqtbl1q_s8(cbq, vld1q_u8(idx));
            const int8x16_t cw1 = vqtbl1q_s8(cbq, vld1q_u8(idx + 16));
            const int8_t *qe0 = a->xq + (size_t)ib * 32;
            for (int t = a->tstart; t < a->tnd; t++) {
                const int8_t *qp = qe0 + (size_t)t * n_in;
                const int8x16_t x0 = vld1q_s8(qp);
                const int8x16_t x1 = vld1q_s8(qp + 16);
                int32x4_t ac = vdupq_n_s32(0);
                ac = vpadalq_s16(ac, vmull_s8(vget_low_s8 (x0), vget_low_s8 (cw0)));
                ac = vpadalq_s16(ac, vmull_s8(vget_high_s8(x0), vget_high_s8(cw0)));
                ac = vpadalq_s16(ac, vmull_s8(vget_low_s8 (x1), vget_low_s8 (cw1)));
                ac = vpadalq_s16(ac, vmull_s8(vget_high_s8(x1), vget_high_s8(cw1)));
                a->y[(size_t)t * n_out + j] += s * a->xs[t] * (float)vaddvq_s32(ac);
            }
        }
    }
}

static void *worker2q(void *p){ run_cols_2q((jobq2_t *)p); return NULL; }


static void qxt_gemm_b2(const uint8_t *w, int n_in, int n_out,
                        const float *x, int T, float *y,
                        const float *cb, int nthreads);
static void qxt_gemm_b3(const uint8_t *w, int n_in, int n_out,
                        const float *x, int T, float *y,
                        const float *cb, int nthreads);

static int i8mm_on(void){ const char *e = getenv("Q4T_I8MM"); return e && e[0]=='2'; }

static void qxt_gemm_b2q(const uint8_t *w, int n_in, int n_out,
                         const float *x, int T, float *y,
                         const float *cb, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    static int8_t *xq_buf = NULL; static float *xs_buf = NULL; static size_t xq_cap = 0;
    size_t need = (size_t)T * n_in;
    if (need > xq_cap) { free(xq_buf); free(xs_buf);
        xq_buf = (int8_t *)malloc(need + 64); xs_buf = (float *)malloc((size_t)T*sizeof(float)+64);
        xq_cap = xq_buf ? need : 0; }
    if (!xq_buf || !xs_buf) { qxt_gemm_b2(w,n_in,n_out,x,T,y,cb,nthreads); return; }
    q8_gemm_xq(x, T, n_in, xq_buf, xs_buf);
    pthread_t th[8]; jobq2_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0;t<nthreads;t++){ int je=js+base+(t<rem?1:0);
        jb[t]=(jobq2_t){w,xq_buf,xs_buf,y,0,T,n_in,n_out,ibp,js,je,cb};
        pthread_create(&th[t],NULL,worker2q,&jb[t]); js=je; }
    for(int t=0;t<nthreads;t++) pthread_join(th[t],NULL);
}

static void qxt_gemm_b3q(const uint8_t *w, int n_in, int n_out,
                         const float *x, int T, float *y,
                         const float *cb, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    static int8_t *xq_buf = NULL; static float *xs_buf = NULL; static size_t xq_cap = 0;
    size_t need = (size_t)T * n_in;
    if (need > xq_cap) { free(xq_buf); free(xs_buf);
        xq_buf = (int8_t *)malloc(need + 64); xs_buf = (float *)malloc((size_t)T*sizeof(float)+64);
        xq_cap = xq_buf ? need : 0; }
    if (!xq_buf || !xs_buf) { qxt_gemm_b3(w,n_in,n_out,x,T,y,cb,nthreads); return; }
    q8_gemm_xq(x, T, n_in, xq_buf, xs_buf);
    pthread_t th[8]; jobq3_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0;t<nthreads;t++){ int je=js+base+(t<rem?1:0);
        jb[t]=(jobq3_t){w,xq_buf,xs_buf,y,0,T,n_in,n_out,ibp,js,je,cb};
        pthread_create(&th[t],NULL,worker3q,&jb[t]); js=je; }
    for(int t=0;t<nthreads;t++) pthread_join(th[t],NULL);
}

static void qxt_gemm_b2(const uint8_t *w, int n_in, int n_out,
                        const float *x, int T, float *y,
                        const float *cb, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    pthread_t th[8]; job2_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t<rem?1:0);
        jb[t] = (job2_t){w, x, y, 0, T, n_in, n_out, ibp, js, je, cb};
        pthread_create(&th[t], NULL, worker2, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}

static void qxt_gemm_b3(const uint8_t *w, int n_in, int n_out,
                        const float *x, int T, float *y,
                        const float *cb, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    pthread_t th[8]; job3_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t<rem?1:0);
        jb[t] = (job3_t){w, x, y, 0, T, n_in, n_out, ibp, js, je, cb};
        pthread_create(&th[t], NULL, worker3, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}

static void qxt_gemm_b4(const uint8_t *w, int n_in, int n_out,
                        const float *x, int T, float *y,
                        const float *cb, int nthreads);

static void qxt_gemm_b4q(const uint8_t *w, int n_in, int n_out,
                         const float *x, int T, float *y,
                         const float *cb, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    // x 量化一次, 全线程共享. 用静态缓冲而非 malloc: 解码时每 token 有
    // 196 次 GEMV 调用, 逐次 malloc/free 的开销在高线程数下反而成为瓶颈
    // (实测 NT=8 全 int8 1.97 tok/s < NT=2 的 3.38).
    static int8_t *xq_buf = NULL; static float *xs_buf = NULL;
    static size_t xq_cap = 0;
    size_t need = (size_t)T * n_in;
    if (need > xq_cap) {
        free(xq_buf); free(xs_buf);
        xq_buf = (int8_t *)malloc(need + 64);
        xs_buf = (float  *)malloc((size_t)T * sizeof(float) + 64);
        xq_cap = xq_buf ? need : 0;
    }
    int8_t *xq = xq_buf; float *xs = xs_buf;
    if (!xq || !xs) { qxt_gemm_b4(w, n_in, n_out, x, T, y, cb, nthreads); return; }
    q8_gemm_xq(x, T, n_in, xq, xs);
    pthread_t th[8]; jobq4_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t<rem?1:0);
        jb[t] = (jobq4_t){w, xq, xs, y, 0, T, n_in, n_out, ibp, js, je, cb};
        pthread_create(&th[t], NULL, worker4q, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}

static void qxt_gemm_b4(const uint8_t *w, int n_in, int n_out,
                        const float *x, int T, float *y,
                        const float *cb, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    {   // Q4T_I8MM=2: 全 int8 (x 量化 + int32 累加, 无浮点转换)
        const char *e = getenv("Q4T_I8MM");
        if (e && e[0]=='2') { qxt_gemm_b4q(w, n_in, n_out, x, T, y, cb, nthreads); return; }
    }
    if (getenv("Q4T_I8MM") != NULL) {           // int8 查表内核 (默认关闭)
        pthread_t th[8]; jobi4_t jb[8];
        int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
        for(int t=0; t<nthreads; t++){
            int je = js + base + (t<rem?1:0);
            jb[t] = (jobi4_t){w, x, y, 0, T, n_in, n_out, ibp, js, je, cb};
            pthread_create(&th[t], NULL, worker4i8, &jb[t]);
            js = je;
        }
        for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
        return;
    }
    pthread_t th[8]; job4_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t<rem?1:0);
        jb[t] = (job4_t){w, x, y, 0, T, n_in, n_out, ibp, js, je, cb};
        pthread_create(&th[t], NULL, worker4, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}

/* 解码 16 字节 nibble -> 32 个 float 码本值 */
static inline void dec16(const uint8_t*bd,const float*hcb,float*f){
    for(int m=0;m<16;m++){ f[2*m]=hcb[bd[m]&0xF]; f[2*m+1]=hcb[bd[m]>>4]; }
}

typedef struct{const uint8_t*w;const float*x;float*y;int t0,t1,n_in,n_out,ibp,js,je;const float*cb;} jobb4_t;

static void*wk4b(void*p){
    jobb4_t*a=(jobb4_t*)p;
    const uint8_t*w=a->w; int ibp=a->ibp,n_in=a->n_in,n_out=a->n_out;
    float hcb[16]; for(int i=0;i<16;i++)hcb[i]=a->cb[i];
    int j=a->js;
    for(;j+3<a->je && (j&3)==0;j+=4){
        for(int t=a->t0;t<a->t1;t++){
            const float*xt=a->x+(size_t)t*n_in;
            float32x4_t ac0=vdupq_n_f32(0),ac1=ac0,ac2=ac0,ac3=ac0;
            for(int ib=0;ib<ibp;ib++){
                const uint8_t*b0=w+((long)j*ibp+ib)*17;
                const uint8_t*b1=b0+(long)ibp*17;
                const uint8_t*b2=b1+(long)ibp*17;
                const uint8_t*b3=b2+(long)ibp*17;
                float f0[32],f1[32],f2[32],f3[32];
                dec16(b0+1,hcb,f0); dec16(b1+1,hcb,f1);
                dec16(b2+1,hcb,f2); dec16(b3+1,hcb,f3);
                const float*xp=xt+ib*32;
                float32x4_t s0=vdupq_n_f32(0),s1=s0,s2=s0,s3=s0;
                for(int e=0;e<32;e+=4){
                    float32x4_t xv=vld1q_f32(xp+e);   /* x 载入一次, 4 列复用 */
                    s0=vmlaq_f32(s0,xv,vld1q_f32(f0+e));
                    s1=vmlaq_f32(s1,xv,vld1q_f32(f1+e));
                    s2=vmlaq_f32(s2,xv,vld1q_f32(f2+e));
                    s3=vmlaq_f32(s3,xv,vld1q_f32(f3+e));
                }
                ac0=vaddq_f32(ac0,vmulq_n_f32(s0,SC_TAB[b0[0]]));
                ac1=vaddq_f32(ac1,vmulq_n_f32(s1,SC_TAB[b1[0]]));
                ac2=vaddq_f32(ac2,vmulq_n_f32(s2,SC_TAB[b2[0]]));
                ac3=vaddq_f32(ac3,vmulq_n_f32(s3,SC_TAB[b3[0]]));
            }
            float*yp=a->y+(size_t)t*n_out+j;         /* 归约只在最后做一次 */
            yp[0]+=vaddvq_f32(ac0); yp[1]+=vaddvq_f32(ac1);
            yp[2]+=vaddvq_f32(ac2); yp[3]+=vaddvq_f32(ac3);
        }
    }
    /* 尾部 */
    for(;j<a->je;j++)
        for(int ib=0;ib<ibp;ib++){
            const uint8_t*blk=w+((long)j*ibp+ib)*17;
            float f[32]; dec16(blk+1,hcb,f);
            const float*xe0=a->x+ib*32;
            for(int t=a->t0;t<a->t1;t++){
                const float*xp=xe0+(size_t)t*n_in;
                float32x4_t su=vdupq_n_f32(0);
                for(int e=0;e<32;e+=4) su=vmlaq_f32(su,vld1q_f32(xp+e),vld1q_f32(f+e));
                a->y[(size_t)t*n_out+j]+=SC_TAB[blk[0]]*vaddvq_f32(su);
            }
        }
    return 0;
}

void qxt_gemm_v2_b4(const uint8_t*w,int n_in,int n_out,const float*x,int T,float*y,
                 const float*cb,int bit,int nthreads){
    tab_init();
    int ibp=n_in/32;
    if(nthreads>n_out) nthreads=n_out>0?n_out:1;
    if(nthreads<1) nthreads=1;
    if(nthreads>8) nthreads=8;
    int ng=(n_out+3)/4, gp=(ng+nthreads-1)/nthreads;
    pthread_t th[8]; jobb4_t jb[8]; int nt=0;
    for(int g=0;g<ng;g+=gp){
        int js=g*4, je=js+gp*4; if(je>n_out) je=n_out;
        jb[nt]=(jobb4_t){w,x,y,0,T,n_in,n_out,ibp,js,je,cb};
        pthread_create(&th[nt],0,wk4b,&jb[nt]); nt++;
        if(nt==8) break;
    }
    for(int t=0;t<nt;t++) pthread_join(th[t],0);
}

void qxt_gemm_v2_b4(const uint8_t *w, int n_in, int n_out, const float *x,
                    int T, float *y, const float *cb, int bit, int nthreads);

void qxt_gemm_t(const uint8_t *w, int n_in, int n_out,
                const float *x, int T, float *y,
                const float *cb, int b, int nthreads){
    if(b==1){ q1t_gemm_impl(w, n_in, n_out, x, T, y, nthreads); return; }
    tab_init();
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    if(b==4){
        /* 默认关闭: 逐张量 1.19~1.43x 是热缓存假象, 端到端仅 1.8%.
           置 Q4T_FAST=1 可启用(等价于 legacy=0), 但实测无收益.
           b=4 真正的瓶颈是 32 步标量码本解码, 而非 FMA —— 要优化得先优化解码. */
        if (getenv("Q4T_FAST") != NULL && getenv("Q4T_LEGACY") == NULL) {
            qxt_gemm_v2_b4(w, n_in, n_out, x, T, y, cb, 4, nthreads); return;
        }
        qxt_gemm_b4(w, n_in, n_out, x, T, y, cb, nthreads); return;
    }
    /* b=3 的 3-bit 码不字节对齐, 本实现仍需 32 次标量索引解包, 实测端到端
       无加速 (p3b3 343.6->342.6ms) 却引入 8.5e-3 量化误差 —— 故默认不走 int8,
       仅在显式设 Q4T_I8MM=3 时启用(供后续做全向量化解包时对比用). */
    if(b==3){ if(getenv("Q4T_I8MM") && getenv("Q4T_I8MM")[0]=='3')
                  qxt_gemm_b3q(w,n_in,n_out,x,T,y,cb,nthreads);
              else qxt_gemm_b3(w,n_in,n_out,x,T,y,cb,nthreads); return; }
    if(b==2){ if(i8mm_on()) qxt_gemm_b2q(w,n_in,n_out,x,T,y,cb,nthreads);
              else         qxt_gemm_b2(w,n_in,n_out,x,T,y,cb,nthreads); return; }
    int ibp = n_in/32;
    pthread_t th[8]; jobx_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t<rem?1:0);
        jb[t] = (jobx_t){w, x, cb, y, 0, T, n_in, n_out, ibp, js, je, b};
        pthread_create(&th[t], NULL, workerx, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}

// --- Q8_0 末投影: y = x @ W_q8, GGUF 列主序 (n_in 最快), 34B/块 {f16 d; i8 qs[32]}
// 用于 token_embd 末投影: 不解压成 fp32, 权重字节量 155MB 而非 622MB.
// x (T,n_in) row-major, y (T,n_out) row-major.
typedef struct { const uint8_t *w; const float *x; float *y;
                 int T, n_in, n_out, ibp, js, je; } jobq_t;

static void run_cols_q8(jobq_t *a){
    const uint8_t *w = a->w; int ibp = a->ibp, n_in = a->n_in, n_out = a->n_out;
    int T = a->T;
    for(int j=a->js; j<a->je; j++){
        // 每 token 独立累加, 权重块共享 -> x 内积重用
        for(int t=0; t<T; t++){
            float acc = 0.f;
            const float *xr = a->x + (size_t)t*n_in;
            for(int ib=0; ib<ibp; ib++){
                const uint8_t *blk = w + ((long)j*ibp + ib)*34;
                float16_t d; memcpy(&d, blk, 2);
                float sd = vgetq_lane_f32(vcvt_f32_f16(vld1_f16((const __fp16*)blk)), 0);
                const int8_t *q = (const int8_t*)(blk+2);
                const float *xp = xr + (size_t)ib*32;
                float32x4_t su = vdupq_n_f32(0.f);
                for(int e=0; e<32; e+=8){
                    int8x8_t qi = vld1_s8(q+e);
                    int16x8_t q16 = vmovl_s8(qi);
                    float32x4_t q0 = vcvtq_f32_s32(vmovl_s16(vget_low_s16(q16)));
                    float32x4_t q1 = vcvtq_f32_s32(vmovl_s16(vget_high_s16(q16)));
                    su = vmlaq_f32(su, q0, vld1q_f32(xp+e));
                    su = vmlaq_f32(su, q1, vld1q_f32(xp+e+4));
                }
                acc += sd * vaddvq_f32(su);
            }
            a->y[(size_t)t*n_out + j] = acc;
        }
    }
}

static void *workerq(void *p){ run_cols_q8((jobq_t*)p); return NULL; }

void q8_gemm_proj(const uint8_t *w, int n_in, int n_out,
                  const float *x, int T, float *y, int nthreads){
    if(nthreads<1) nthreads=1; if(nthreads>8) nthreads=8;
    int ibp = n_in/32;
    pthread_t th[8]; jobq_t jb[8];
    int base = n_out/nthreads, rem = n_out%nthreads, js = 0;
    for(int t=0; t<nthreads; t++){
        int je = js + base + (t<rem?1:0);
        jb[t] = (jobq_t){w, x, y, T, n_in, n_out, ibp, js, je};
        pthread_create(&th[t], NULL, workerq, &jb[t]);
        js = je;
    }
    for(int t=0; t<nthreads; t++) pthread_join(th[t], NULL);
}