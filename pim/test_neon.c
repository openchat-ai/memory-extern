#include <arm_neon.h>
#include <stdio.h>
int main() {
    float a[4] = {1,2,3,4}, b[4] = {5,6,7,8};
    float32x4_t va = vld1q_f32(a);
    float32x4_t vb = vld1q_f32(b);
    float32x4_t vc = vfmaq_f32(va, vb, vb);
    float r[4]; vst1q_f32(r, vc);
    printf("%f %f %f %f\n", r[0], r[1], r[2], r[3]);
    return 0;
}
