/* 精确标定 SMMLA (ARMv8.6 i8mm) 的语义与吞吐.
 *
 * SMMLA Vd.4S, Vn.16B, Vm.16B :
 *   Vn.16B 被视作 2x8 矩阵 Rn (2 行, 每行 8 字节)
 *   Vm.16B 被视作 8x2 矩阵 Cm (8 行, 每行 2 字节)
 *   Vd.4S += Rn · Cm, 即 4 个 int32 累加器:
 *     d[0] += sum_k Rn[0][k]*Cm[k][0]
 *     d[1] += sum_k Rn[0][k]*Cm[k][1]
 *     d[2] += sum_k Rn[1][k]*Cm[k][0]
 *     d[3] += sum_k Rn[1][k]*Cm[k][1]
 *   => 单条指令 2x2x8 = 32 次 MAC (不是 64)
 */
#include <arm_neon.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define N 512
#define ITERS 40000

static int8_t A[N] __attribute__((aligned(16)));
static int8_t B[N] __attribute__((aligned(16)));
static int8_t A2[N] __attribute__((aligned(16)));
static int32_t C[N] __attribute__((aligned(16)));

/* ---- 语义标定: 用全 1 的输入, 结果应等于 k 长度 ---- */
__attribute__((target("i8mm")))
int32_t smmla_ones(int reps) {
    int32x4_t acc = vdupq_n_s32(0);
    uint8x16_t ones = vdupq_n_u8(1);
    for (int i = 0; i < reps; i++) acc = vmmlaq_s32(acc, ones, ones);
    return vaddvq_s32(acc);
}

/* ---- 计数: 用可区分的值验证布局 ---- */
__attribute__((target("i8mm")))
void smmla_layout(int8_t *a, int8_t *b, int32_t *out) {
    int32x4_t acc = vdupq_n_s32(0);
    uint8x16_t va = vreinterpretq_u8_s8(vld1q_s8(a));
    uint8x16_t vb = vreinterpretq_u8_s8(vld1q_s8(b));
    acc = vmmlaq_s32(acc, va, vb);
    vst1q_s32(out, acc);
}

/* ---- 吞吐: 累加 8 个累加器, 抵消延迟 ---- */
__attribute__((target("i8mm")))
int32_t kern_i8mm(const int8_t *a, const int8_t *b, int n) {
    int32x4_t c0 = vdupq_n_s32(0), c1 = c0, c2 = c0, c3 = c0;
    int32x4_t c4 = c0, c5 = c0, c6 = c0, c7 = c0;
    for (int i = 0; i < n; i += 64) {
        uint8x16_t b0 = vreinterpretq_u8_s8(vld1q_s8(b + i));
        uint8x16_t b1 = vreinterpretq_u8_s8(vld1q_s8(b + i + 16));
        uint8x16_t b2 = vreinterpretq_u8_s8(vld1q_s8(b + i + 32));
        uint8x16_t b3 = vreinterpretq_u8_s8(vld1q_s8(b + i + 48));
        c0 = vmmlaq_s32(c0, b0, vreinterpretq_u8_s8(vld1q_s8(a + i)));
        c1 = vmmlaq_s32(c1, b1, vreinterpretq_u8_s8(vld1q_s8(a + i + 16)));
        c2 = vmmlaq_s32(c2, b2, vreinterpretq_u8_s8(vld1q_s8(a + i + 32)));
        c3 = vmmlaq_s32(c3, b3, vreinterpretq_u8_s8(vld1q_s8(a + i + 48)));
        c4 = vmmlaq_s32(c4, b0, vreinterpretq_u8_s8(vld1q_s8(a + i + 64)));
        c5 = vmmlaq_s32(c5, b1, vreinterpretq_u8_s8(vld1q_s8(a + i + 80)));
        c6 = vmmlaq_s32(c6, b2, vreinterpretq_u8_s8(vld1q_s8(a + i + 96)));
        c7 = vmmlaq_s32(c7, b3, vreinterpretq_u8_s8(vld1q_s8(a + i + 112)));
    }
    return vaddvq_s32(c0) + vaddvq_s32(c1) + vaddvq_s32(c2) + vaddvq_s32(c3)
         + vaddvq_s32(c4) + vaddvq_s32(c5) + vaddvq_s32(c6) + vaddvq_s32(c7);
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + 1e-9 * t.tv_nsec;
}

int main(void) {
    printf("=== 1. SMMLA 语义标定 ===\n");
    /* 全 1: 每条指令每个累加器加 8 */
    int32_t r1 = smmla_ones(1), r10 = smmla_ones(10);
    printf("  全1 输入, 1 次 = %d (期望 32 = 4x8)\n", r1);
    printf("  全1 输入, 10 次 = %d (期望 320)\n", r10);

    /* 布局: A 字节 = [0..15], B 字节 = [0..15] 递增 */
    int8_t a[16], b[16];
    for (int i = 0; i < 16; i++) { a[i] = (int8_t)i; b[i] = (int8_t)i; }
    int32_t out[4];
    smmla_layout(a, b, out);
    printf("  A=B=[0..15] 时 Vd = [%d %d %d %d]\n", out[0], out[1], out[2], out[3]);
    /* 参考: Rn = A 视作 2x8, Cm = B 视作 8x2 */
    printf("  参考计算:\n");
    for (int r = 0; r < 2; r++)
        for (int c = 0; c < 2; c++) {
            int s = 0;
            for (int k = 0; k < 8; k++) s += a[r * 8 + k] * b[k * 2 + c];
            printf("    d[%d] = %d\n", r * 2 + c, s);
        }

    printf("\n=== 2. 吞吐标定 (n=%d, 每调用 8x8 次 SMMLA) ===\n", N);
    for (int i = 0; i < N; i++) { A[i] = 1; B[i] = 1; }

    /* fp32 对照 */
    double t = now();
    volatile float sink = 0;
    {
        float32x4_t c0 = vdupq_n_f32(0), c1 = c0, c2 = c0, c3 = c0;
        const float *pa = (const float *)A, *pb = (const float *)B;
        for (int r = 0; r < ITERS; r++) {
            asm volatile("" : "+r"(pa), "+r"(pb));
            for (int i = 0; i < N; i += 16) {
                c0 = vmlaq_n_f32(c0, vld1q_f32(pa + i),      1.0f);
                c1 = vmlaq_n_f32(c1, vld1q_f32(pa + i + 4),  1.0f);
                c2 = vmlaq_n_f32(c2, vld1q_f32(pa + i + 8),  1.0f);
                c3 = vmlaq_n_f32(c3, vld1q_f32(pa + i + 12), 1.0f);
            }
        }
        sink = vaddvq_f32(c0) + vaddvq_f32(c1) + vaddvq_f32(c2) + vaddvq_f32(c3);
    }
    double d32 = now() - t;
    double macs32 = (double)ITERS * (N / 16 * 16);
    printf("  fp32 FMA : %7.1f GMAC/s  (%d 条 vmlaq/次)\n",
           macs32 / d32 / 1e9, N / 16 * 4);

    t = now();
    volatile int32_t isink = 0;
    {
        const int8_t *pa = A, *pb = B;
        for (int r = 0; r < ITERS; r++) {
            asm volatile("" : "+r"(pa), "+r"(pb));
            isink = kern_i8mm(pa, pb, N);
        }
    }
    double di8 = now() - t;
    double macsi8 = (double)ITERS * (N / 64 * 8 * 32);
    printf("  i8mm SMMLA: %7.1f GMAC/s  (%d 条 vmmlaq/次 x 32 MAC)\n",
           macsi8 / di8 / 1e9, N / 64 * 8);
    printf("\n  i8mm 相对 fp32: %.2fx (算术吞吐)\n",
           (macsi8 / di8) / (macs32 / d32));
    printf("  (校验 fp32=%.0f i8=%d)\n", sink, isink);
    return 0;
}