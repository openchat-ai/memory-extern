// qxn_kernels.c — QxN 训练热点的 NEON 实现 (供 qxn_train.py ctypes 调用).
//
// 为什么需要 C: profile 实测 (L=4 d=128, batch=16) 显示
//   forward  39%  /  backward 61%
// 其中 gelu+bwd 占 14%, binarize_w 4%, _quant_act 2% —— 都是逐元素操作,
// numpy 每个元素一次函数调用/临时数组, C + NEON 可快 5-20x.
//
// 注意: 这些函数都是**逐元素 / 沿最后一维归约**的, 不涉及大矩阵乘,
// 因此不存在"用移位替代矩阵乘"的可能 (矩阵乘是 MAC 累加, 位运算无法替代).
// b=1 权重的符号化在**推理**侧才退化为带符号求和 (见 q1t_gemm.c sign_sum).
//
// Build:
//   clang -O3 -march=armv8-a -shared -fPIC qxn_kernels.c -o qxn_kernels.so -lm
#include <arm_neon.h>
#include <stdint.h>
#include <math.h>

#define QXN_SQRT_2_OVER_PI 0.7978845608028654f
#define GELU_K 0.044715f

// AArch64 基线无 float tanh/exp 向量指令 (要 ARMv8.2). tanh 用标量 expf
// 展开: tanh(z) = 1 - 2/(exp(2z)+1). expf 本身很快, 且这里只占 4 lane.
static inline float32x4_t qxn_tanh4(float32x4_t v) {
    float z[4], o[4];
    vst1q_f32(z, v);
    for (int i = 0; i < 4; i++) o[i] = tanhf(z[i]);
    return vld1q_f32(o);
}

// ---------------------------------------------------------------- gelu
// tanh 近似, 与 python 版逐字对齐:
//   0.5*x*(1+tanh(c*(x + 0.044715*x^3)))
void qxn_gelu(const float *x, float *y, long n) {
    long i = 0;
    const float32x4_t vc = vdupq_n_f32(QXN_SQRT_2_OVER_PI);
    const float32x4_t vk = vdupq_n_f32(GELU_K);
    const float32x4_t vhalf = vdupq_n_f32(0.5f);
    const float32x4_t vone = vdupq_n_f32(1.0f);
    for (; i + 4 <= n; i += 4) {
        float32x4_t xv = vld1q_f32(x + i);
        float32x4_t x3 = vmulq_f32(xv, vmulq_f32(xv, xv));
        float32x4_t inner = vmulq_f32(vc,
            vaddq_f32(xv, vmulq_f32(vk, x3)));
        float32x4_t t = qxn_tanh4(inner);
        float32x4_t r = vmulq_f32(vhalf,
            vmulq_f32(xv, vaddq_f32(vone, t)));
        vst1q_f32(y + i, r);
    }
    for (; i < n; i++) {
        float xv = x[i];
        float inner = QXN_SQRT_2_OVER_PI * (xv + GELU_K * xv * xv * xv);
        y[i] = 0.5f * xv * (1.0f + tanhf(inner));
    }
}

// gelu 的解析导数 (与 python gelu_bwd 完全一致)
//   d = 0.5*(1+t) + 0.5*x*(1-t^2)*c*(1 + 3*0.044715*x^2),  t = tanh(inner)
// y[i] = gelu'(x[i]) * dy[i]
void qxn_gelu_bwd_mul(const float *x, const float *dy, float *y, long n) {
    long i = 0;
    const float32x4_t vc = vdupq_n_f32(QXN_SQRT_2_OVER_PI);
    const float32x4_t vk = vdupq_n_f32(GELU_K);
    const float32x4_t vhalf = vdupq_n_f32(0.5f);
    const float32x4_t vone = vdupq_n_f32(1.0f);
    const float32x4_t vthree_k = vdupq_n_f32(3.0f * GELU_K);
    for (; i + 4 <= n; i += 4) {
        float32x4_t xv = vld1q_f32(x + i);
        float32x4_t dyv = vld1q_f32(dy + i);
        float32x4_t x2 = vmulq_f32(xv, xv);
        float32x4_t x3 = vmulq_f32(xv, x2);
        float32x4_t inner = vmulq_f32(vc, vaddq_f32(xv, vmulq_f32(vk, x3)));
        float32x4_t t = qxn_tanh4(inner);
        float32x4_t t2 = vmulq_f32(t, t);
        float32x4_t a = vmulq_f32(vhalf, vaddq_f32(vone, t));
        float32x4_t b = vmulq_f32(vmulq_f32(vhalf, xv),
                        vmulq_f32(vsubq_f32(vone, t2),
                        vmulq_f32(vc, vaddq_f32(vone,
                            vmulq_f32(vthree_k, x2)))));
        vst1q_f32(y + i, vmulq_f32(dyv, vaddq_f32(a, b)));
    }
    for (; i < n; i++) {
        float xv = x[i], dyv = dy[i];
        float inner = QXN_SQRT_2_OVER_PI * (xv + GELU_K * xv * xv * xv);
        float t = tanhf(inner);
        float d = 0.5f * (1 + t) + 0.5f * xv * (1 - t * t) *
                  QXN_SQRT_2_OVER_PI * (1 + 3 * GELU_K * xv * xv);
        y[i] = dyv * d;
    }
}

// ------------------------------------------------------- binarize (sign)
void qxn_sign(const float *x, float *y, long n) {
    long i = 0;
    for (; i + 4 <= n; i += 4) {
        float32x4_t v = vld1q_f32(x + i);
        // NEON 没有 float sign 指令: 用比较生成掩码再选 ±1
        uint32x4_t neg = vcltq_f32(v, vdupq_n_f32(0.f));
        float32x4_t r = vbslq_f32(neg, vdupq_n_f32(-1.0f), vdupq_n_f32(1.0f));
        // sign(0) = 0 (与 numpy 一致)
        uint32x4_t z = vceqq_f32(v, vdupq_n_f32(0.f));
        r = vbslq_f32(z, vdupq_n_f32(0.0f), r);
        vst1q_f32(y + i, r);
    }
    for (; i < n; i++) {
        y[i] = (x[i] > 0.f) ? 1.0f : ((x[i] < 0.f) ? -1.0f : 0.0f);
    }
}

// ------------------------------------------------------------- RMSNorm
// y = x * rstd * g,  rstd = 1/sqrt(mean(x^2)+eps), 沿最后一维 (d) 归约
// x:(n, d)  g:(d)
void qxn_rmsnorm(const float *x, const float *g, float *y,
                 float *rstd_out, long n, int d, float eps) {
    for (long r = 0; r < n; r++) {
        const float *xr = x + r * d;
        float *yr = y + r * d;
        float32x4_t acc = vdupq_n_f32(0.f);
        int i = 0;
        for (; i + 4 <= d; i += 4)
            acc = vaddq_f32(acc, vmulq_f32(vld1q_f32(xr + i),
                                           vld1q_f32(xr + i)));
        float s = vaddvq_f32(acc);
        for (; i < d; i++) s += xr[i] * xr[i];
        float rstd = 1.0f / sqrtf(s / (float)d + eps);
        if (rstd_out) rstd_out[r] = rstd;
        const float32x4_t vr = vdupq_n_f32(rstd);
        int j = 0;
        for (; j + 4 <= d; j += 4)
            vst1q_f32(yr + j, vmulq_f32(vmulq_f32(vld1q_f32(xr + j), vr),
                                        vld1q_f32(g + j)));
        for (; j < d; j++) yr[j] = xr[j] * rstd * g[j];
    }
}

// dx = rstd*dy*g - x*rstd^3*mean(dy*g*x)
// dg[j] = sum_r dy[r,j]*x[r,j]*rstd[r]
void qxn_rmsnorm_bwd(const float *x, const float *dy, const float *g,
                     const float *rstd, float *dx, float *dg,
                     long n, int d, float eps) {
    for (int j = 0; j < d; j++) dg[j] = 0.f;
    for (long r = 0; r < n; r++) {
        const float *xr = x + r * d;
        const float *dyr = dy + r * d;
        float *dxr = dx + r * d;
        float rs = rstd[r];
        // mean(dy*g*x)
        float32x4_t acc = vdupq_n_f32(0.f);
        int i = 0;
        for (; i + 4 <= d; i += 4) {
            float32x4_t xv = vld1q_f32(xr + i);
            float32x4_t t = vmulq_f32(vmulq_f32(vld1q_f32(dyr + i),
                                               vld1q_f32(g + i)), xv);
            acc = vaddq_f32(acc, t);
        }
        float m = vaddvq_f32(acc);
        for (; i < d; i++) m += dyr[i] * g[i] * xr[i];
        m /= (float)d;
        float coef = rs * rs * rs * m;      // x * rstd^3 * mean
        float32x4_t vr = vdupq_n_f32(rs);
        float32x4_t vc = vdupq_n_f32(coef);
        int j = 0;
        for (; j + 4 <= d; j += 4) {
            float32x4_t xv = vld1q_f32(xr + j);
            float32x4_t t = vmulq_f32(vmulq_f32(vld1q_f32(dyr + j),
                                               vld1q_f32(g + j)), vr);
            vst1q_f32(dxr + j, vsubq_f32(t, vmulq_f32(xv, vc)));
            dg[j + 0] += dyr[j + 0] * xv[j + 0] * rs;
            dg[j + 1] += dyr[j + 1] * xv[j + 1] * rs;
            dg[j + 2] += dyr[j + 2] * xv[j + 2] * rs;
            dg[j + 3] += dyr[j + 3] * xv[j + 3] * rs;
        }
        for (; j < d; j++) {
            dxr[j] = dyr[j] * g[j] * rs - xr[j] * coef;
            dg[j] += dyr[j] * xr[j] * rs;
        }
    }
}

// ------------------------------------------------------- 激活量化 (BitNet)
// mode 0: absmean  1: absmax     clamp: 量化上下界 (BitNet 用 127)
// x:(..., d) 最后一维归约; 返回量化后的值, s_out 保存每行 scale
void qxn_quant_act(const float *x, float *y, float *s_out,
                   long n, int d, int use_absmax, float clamp_v,
                   int to_binary) {
    const float c = clamp_v;
    const float inv = 1.0f / c;
    for (long r = 0; r < n; r++) {
        const float *xr = x + r * d;
        float *yr = y + r * d;
        if (to_binary) {
            int i = 0;
            for (; i + 4 <= d; i += 4) {
                float32x4_t v = vld1q_f32(xr + i);
                uint32x4_t neg = vcltq_f32(v, vdupq_n_f32(0.f));
                float32x4_t rr = vbslq_f32(neg, vdupq_n_f32(-1.0f),
                                          vdupq_n_f32(1.0f));
                uint32x4_t z = vceqq_f32(v, vdupq_n_f32(0.f));
                vst1q_f32(yr + i, vbslq_f32(z, vdupq_n_f32(0.f), rr));
            }
            for (; i < d; i++)
                yr[i] = (xr[i] > 0.f) ? 1.f : ((xr[i] < 0.f) ? -1.f : 0.f);
            continue;
        }
        // 求 absmean 或 absmax
        float s;
        if (use_absmax) {
            float32x4_t am = vdupq_n_f32(0.f);
            int i = 0;
            for (; i + 4 <= d; i += 4)
                am = vmaxq_f32(am, vabsq_f32(vld1q_f32(xr + i)));
            s = vmaxvq_f32(am);
            for (; i < d; i++) { float a = fabsf(xr[i]); if (a > s) s = a; }
        } else {
            float32x4_t acc = vdupq_n_f32(0.f);
            int i = 0;
            for (; i + 4 <= d; i += 4)
                acc = vaddq_f32(acc, vabsq_f32(vld1q_f32(xr + i)));
            s = vaddvq_f32(acc);
            for (; i < d; i++) s += fabsf(xr[i]);
            s /= (float)d;
        }
        float scale = s / c;
        if (scale < 1e-8f) scale = 1e-8f;
        if (s_out) s_out[r] = scale;
        float32x4_t vs = vdupq_n_f32(scale);
        float32x4_t vc = vdupq_n_f32(c);
        float32x4_t vnegc = vdupq_n_f32(-c);
        int j = 0;
        for (; j + 4 <= d; j += 4) {
            // q = round(x / scale) —— 用真除法, 避免 1/scale 的乘法误差
            float32x4_t q = vrndaq_f32(vdivq_f32(vld1q_f32(xr + j), vs));
            q = vminq_f32(vmaxq_f32(q, vnegc), vc);
            vst1q_f32(yr + j, vmulq_f32(q, vs));
        }
        for (; j < d; j++) {
            float q = roundf(xr[j] / scale);
            if (q > c) q = c;
            if (q < -c) q = -c;
            yr[j] = q * scale;
        }
    }
}