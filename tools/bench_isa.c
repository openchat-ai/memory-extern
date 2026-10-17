/* 验证核心命题: 加速比取决于「每条指令能完成多少 MAC」, 而非位宽本身.
 *
 * 三档对比(同一颗 CPU, 128-bit NEON 向量):
 *   fp32  FMA          : 每指令 4 个 fp32 MAC
 *   int8  dotprod(asimddp): 每指令 16 个 int8 MAC (4 lane x 4)
 *   i8mm  smmla        : 每指令 128 个 int8 MAC (2 个 8x8 块)
 *
 * 编译(各内核用独立 target attribute, 避免 -march=native 生成非法指令):
 *   clang -O3 -o isa isa.c
 */
#include <arm_neon.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define ITERS 20000
#define N 4096

/* ---- fp32: 4 个累加器, 每条 vmlaq_f32 完成 4 个 MAC ---- */
__attribute__((target("neon")))
float kern_f32(const float *a, const float *b, int n, int seed) {
    (void)seed;
    float32x4_t c0 = vdupq_n_f32(0), c1 = c0, c2 = c0, c3 = c0;
    for (int i = 0; i < n; i += 16) {
        c0 = vmlaq_n_f32(c0, vld1q_f32(a + i),      b[i]);
        c1 = vmlaq_n_f32(c1, vld1q_f32(a + i + 4),  b[i + 4]);
        c2 = vmlaq_n_f32(c2, vld1q_f32(a + i + 8),  b[i + 8]);
        c3 = vmlaq_n_f32(c3, vld1q_f32(a + i + 12), b[i + 12]);
    }
    return vaddvq_f32(c0) + vaddvq_f32(c1) + vaddvq_f32(c2) + vaddvq_f32(c3);
}

/* ---- int8 + asimddp: 每条 vdotl_s32 完成 4 个 int8 MAC, 每轮 4 条 = 16 ---- */
static inline int32x4_t sdot_(int32x4_t acc, int8x16_t a, int8x16_t b) {
    asm volatile("sdot %0.4s, %1.16b, %2.16b"
                 : "+w"(acc) : "w"(a), "w"(b));
    return acc;
}
__attribute__((target("+dotprod")))
int32_t kern_i8_dot(const int8_t *a, const int8_t *b, int n, int seed) {
    (void)seed;
    int32x4_t c0 = vdupq_n_s32(0), c1 = c0, c2 = c0, c3 = c0;
    for (int i = 0; i < n; i += 64) {
        c0 = sdot_(c0, vld1q_s8(a + i),      vld1q_s8(b + i));
        c1 = sdot_(c1, vld1q_s8(a + i + 16), vld1q_s8(b + i + 16));
        c2 = sdot_(c2, vld1q_s8(a + i + 32), vld1q_s8(b + i + 32));
        c3 = sdot_(c3, vld1q_s8(a + i + 48), vld1q_s8(b + i + 48));
        c0 = vsetq_lane_s32(seed, c0, 0);
    }
    return vaddvq_s32(c0) + vaddvq_s32(c1) + vaddvq_s32(c2) + vaddvq_s32(c3);
}

/* ---- i8mm: 每条 vmmlaq_s32 完成 8x8=64 个 int8 MAC ---- */
__attribute__((target("i8mm")))
int32_t kern_i8mm(const int8_t *a, const int8_t *b, int n, int seed) {
    (void)seed;
    int32x4_t c0 = vdupq_n_s32(0), c1 = c0, c2 = c0, c3 = c0;
    for (int i = 0; i < n; i += 64) {
        uint8x16_t b0 = vreinterpretq_u8_s8(vld1q_s8(b + i));
        uint8x16_t b1 = vreinterpretq_u8_s8(vld1q_s8(b + i + 16));
        c0 = vmmlaq_s32(c0, b0, vreinterpretq_u8_s8(vld1q_s8(a + i)));
        c1 = vmmlaq_s32(c1, b0, vreinterpretq_u8_s8(vld1q_s8(a + i + 16)));
        c2 = vmmlaq_s32(c2, b1, vreinterpretq_u8_s8(vld1q_s8(a + i + 32)));
        c3 = vmmlaq_s32(c3, b1, vreinterpretq_u8_s8(vld1q_s8(a + i + 48)));
        c0 = vsetq_lane_s32(seed, c0, 0);
    }
    return vaddvq_s32(c0) + vaddvq_s32(c1) + vaddvq_s32(c2) + vaddvq_s32(c3);
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + 1e-9 * t.tv_nsec;
}

int main(void) {
    static float af[N] __attribute__((aligned(16)));
    static float bf[N] __attribute__((aligned(16)));
    static int8_t ai[N] __attribute__((aligned(16)));
    static int8_t bi[N] __attribute__((aligned(16)));
    for (int i = 0; i < N; i++) { af[i] = 1.0f; bf[i] = 1.0f; ai[i] = 1; bi[i] = 1; }

    /* 每次内核调用(n=64):
     *  fp32  : 16 条 vmlaq_n_f32 x 4 MAC = 64 MAC
     *  i8dot :  4 条 sdot(16B)      x 16 MAC = 64 MAC
     *  i8mm  :  4 条 vmmlaq(8x8)    x 64 MAC = 256 MAC */
    const double M_f32 = N, M_i8dot = N, M_i8mm = N*4;   /* 每次调用的 MAC 数 */
    volatile float sink = 0; volatile int32_t isink = 0;

    printf("%-22s %12s %12s %12s %12s\n", "内核", "ns/轮", "MMAC/s", "指令/轮",
           "MAC/指令");
    printf("-------------------------------------------------------------------------\n");

    double t = now();
    float s = 0;
    const float *pa = af, *pb = bf;
    for (int r = 0; r < ITERS; r++) {
        asm volatile("" : "+r"(pa), "+r"(pb));
        s += kern_f32(pa, pb, N, r);
    }
    sink = s;
    double d1 = now() - t;
    printf("%-22s %12.2f %12.1f %12d %12.1f\n", "fp32 FMA", d1 / ITERS * 1e6,
           M_f32 * ITERS / d1 / 1e9, (int)(N/16*4), M_f32 / (N/16*4));

    t = now();
    int32_t s2 = 0;
    const int8_t *qa = ai, *qb = bi;
    for (int r = 0; r < ITERS; r++) {
        asm volatile("" : "+r"(qa), "+r"(qb));
        s2 += kern_i8_dot(qa, qb, N, r);
    }
    isink = s2;
    double d2 = now() - t;
    printf("%-22s %12.2f %12.1f %12d %12.1f\n", "int8 dotprod", d2 / ITERS * 1e6,
           M_i8dot * ITERS / d2 / 1e9, (int)(N/64*4), M_i8dot / (N/64*4));

    t = now();
    int32_t s3 = 0;
    const int8_t *ra = ai, *rb = bi;
    for (int r = 0; r < ITERS; r++) {
        asm volatile("" : "+r"(ra), "+r"(rb));
        s3 += kern_i8mm(ra, rb, N, r);
    }
    isink = isink + s3;
    double d3 = now() - t;
    printf("%-22s %12.2f %12.1f %12d %12.1f\n", "i8mm smmla", d3 / ITERS * 1e6,
           M_i8mm * ITERS / d3 / 1e9, (int)(N/64*4), M_i8mm / (N/64*4));

    double g32 = M_f32 * ITERS / d1 / 1e9, gd = M_i8dot * ITERS / d2 / 1e9,
       gm = M_i8mm * ITERS / d3 / 1e9;
    printf("\n实际吞吐 (GMAC/s) 与相对加速:\n");
    printf("  fp32 FMA      : %8.1f GMAC/s   1.00x\n", g32);
    printf("  int8 dotprod  : %8.1f GMAC/s   %.2fx\n", gd, gd / g32);
    printf("  i8mm  smmla   : %8.1f GMAC/s   %.2fx\n", gm, gm / g32);
    printf("\n拆解: 吞吐 = (每指令 MAC 数) x (发射率)\n");
    printf("  %-14s %12s %12s %12s\n", "内核", "MAC/指令", "相对fp32", "隐含发射率");
    printf("  %-14s %12.0f %12.2f %12.2f\n", "fp32 FMA", M_f32/(N/16*4), 1.0, 1.00);
    printf("  %-14s %12.0f %12.2f %12.2f\n", "int8 dotprod", M_i8dot/(N/64*4), 16.0/(M_f32/(N/16*4)), (gd/g32)/(16.0/(M_f32/(N/16*4))));
    printf("  %-14s %12.0f %12.2f %12.2f\n", "i8mm smmla", M_i8mm/(N/64*4), (M_i8mm/(N/64*4))/(M_f32/(N/16*4)), (gm/g32)/((M_i8mm/(N/64*4))/(M_f32/(N/16*4))));
    printf("(校验和 f=%.0f i8dot=%d i8mm=%d, sink=%f/%d)\n", s, s2, s3, sink, isink);
    return 0;
}