/* q4t_encode.c — Q4T 块编码器 (供 qxt_repack.py ctypes 调用).
 *
 * 对每 32 元素块: 搜 n_cand 个候选 scale, 选块内 max|err| 最小的.
 * 与 tools/q4f8_codebook.py::_enc_block 数值一致.
 *
 * 编译:
 *   clang -O3 -fPIC -shared -o tools/q4t_encode.so tools/q4t_encode.c -lm
 */
#include <math.h>
#include <stdint.h>

#define QK 32

static float scale_of(int sc, float log_lo, float sc_step) {
    return powf(2.0f, log_lo + (float)sc * sc_step);
}

/* W: (nblocks, 32) float; codebook: (16) float (升序, 最大=cb[15]);
 * 输出 scales:(nblocks) uint8, codes:(nblocks,16) uint8 (lo nibble 打包).
 */
void q4t_encode_blocks(const float *W, long nblocks,
                       uint8_t *scales, uint8_t *codes,
                       const float *codebook, float log_lo, float sc_step,
                       int n_cand)
{
    const float cbmax = codebook[15];
    const int half = n_cand / 2;
    for (long b = 0; b < nblocks; b++) {
        const float *x = W + b * QK;
        float ampl = 0.0f;
        for (int i = 0; i < QK; i++) {
            float a = fabsf(x[i]);
            if (a > ampl) ampl = a;
        }
        if (ampl <= 0.0f) {
            scales[b] = 0;
            for (int i = 0; i < 16; i++) codes[b*16+i] = 0;
            continue;
        }
        float dbase = ampl / cbmax;
        float l = log2f(dbase);
        int center = (int)lroundf((l - log_lo) / sc_step);
        if (center < 0) center = 0;
        if (center > 127) center = 127;

        int best_sc = center;
        float best_err = 1e30f;
        for (int k = -half; k <= half; k++) {
            int sc = center + k;
            if (sc < 0 || sc > 127) continue;
            float d = scale_of(sc, log_lo, sc_step);
            float err = 0.0f;
            for (int i = 0; i < QK; i++) {
                /* 找最近 codebook 值 */
                float best_d = 1e30f;
                for (int j = 0; j < 16; j++) {
                    float diff = fabsf(x[i] - d * codebook[j]);
                    if (diff < best_d) best_d = diff;
                }
                if (best_d > err) err = best_d;
            }
            if (err < best_err) { best_err = err; best_sc = sc; }
        }
        float d = scale_of(best_sc, log_lo, sc_step);
        uint8_t code[QK];
        for (int i = 0; i < QK; i++) {
            int best_j = 0; float best_d = 1e30f;
            for (int j = 0; j < 16; j++) {
                float diff = fabsf(x[i] - d * codebook[j]);
                if (diff < best_d) { best_d = diff; best_j = j; }
            }
            code[i] = (uint8_t)best_j;
        }
        scales[b] = (uint8_t)best_sc;
        for (int i = 0; i < 16; i++)
            codes[b*16+i] = (uint8_t)(code[2*i] | (code[2*i+1] << 4));
    }
}
