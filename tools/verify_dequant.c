// 用官方 gguf_init_from_file 加载张量数据，与 C 工具 dequant 输出对比
// gcc verify_dequant.c -lggml-base -lggml-cpu
#include "gguf.h"
#include "ggml.h"
#include "ggml-quants.h"
#include <stdio.h>
#include <string.h>
#include <math.h>

static void dump_stats(const char *name, const float *y, int n) {
    double s = 0, ss = 0; float mn = 1e30f, mx = -1e30f;
    for (int i = 0; i < n; i++) {
        if (!isfinite(y[i])) { printf("  NONFINITE at %d: %g\n", i, y[i]); return; }
        s += y[i]; ss += (double)y[i] * y[i];
        if (y[i] < mn) mn = y[i];
        if (y[i] > mx) mx = y[i];
    }
    double rms = sqrt(ss / n);
    printf("%s: min=%.5g max=%.5g rms=%.5g mean=%.5g\n", name, mn, mx, rms, s / n);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s model.gguf\n", argv[0]); return 1; }
    struct gguf_init_params params = { .no_alloc = true, .ctx = NULL };
    struct gguf_context *ctx = gguf_init_from_file(argv[1], params);
    if (!ctx) { fprintf(stderr, "gguf_init failed\n"); return 1; }

    printf("data_offset=%zu alignment=%zu\n",
           gguf_get_data_offset(ctx), gguf_get_alignment(ctx));
    const char *names[] = {
        "blk.0.ffn_gate_exps.weight",
        "blk.0.ffn_down_exps.weight",
        "blk.0.ssm_out.weight",
        "token_embd.weight",
    };
    for (int i = 0; i < 4; i++) {
        int idx = -1;
        for (size_t j = 0; j < gguf_get_n_tensors(ctx); j++)
            if (strcmp(gguf_get_tensor_name(ctx, j), names[i]) == 0) { idx = (int)j; break; }
        if (idx < 0) { printf("%s: NOT FOUND\n", names[i]); continue; }
        struct ggml_tensor *t = ggml_get_tensor(*params.ctx, names[i]);
        size_t off = gguf_get_tensor_offset(ctx, idx);
        size_t nbt = gguf_get_tensor_size(ctx, idx);
        printf("%s: type=%d dims=(%lld,%lld,%lld) offset=%zu nbytes=%zu\n",
               names[i], t->type,
               (long long)t->ne[0], (long long)t->ne[1], (long long)t->ne[2],
               (size_t)off, nbt);
    }
    gguf_free(ctx);
    return 0;
}
