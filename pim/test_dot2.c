#include <arm_neon.h>
#include <stdio.h>
int main() {
    int8x16_t a = vdupq_n_s8(1);
    int8x16_t b = vdupq_n_s8(2);
    int32x4_t r = vdotq_s32(vdupq_n_s32(0), a, b);
    int32_t out[4]; vst1q_s32(out, r);
    printf("vdotq_s32 result: %d %d %d %d\n", out[0], out[1], out[2], out[3]);
    return 0;
}
