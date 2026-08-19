#include "gguf.h"
#include "ggml.h"
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc < 2) return 1;
    struct gguf_init_params params = {
        /*.no_alloc = */ true,
        /*.ctx      = */ NULL,
    };
    struct gguf_context * ctx = gguf_init_from_file(argv[1], params);
    if (!ctx) { fprintf(stderr, "gguf_init fail\n"); return 1; }
    fprintf(stderr, "alignment=%zu data_offset=%zu\n", gguf_get_alignment(ctx), gguf_get_data_offset(ctx));
    fprintf(stderr, "--- KV list ---\n");
    for (int64_t i = 0; i < gguf_get_n_kv(ctx); i++) {
        fprintf(stderr, "KV[%lld] %s type=%d\n", (long long)i, gguf_get_key(ctx, i), gguf_get_kv_type(ctx, i));
    }
    const char *tname = "blk.0.ffn_gate_exps.weight";
    int64_t id = gguf_find_tensor(ctx, tname);
    if (id < 0) { fprintf(stderr, "tensor not found\n"); return 1; }
    size_t toff = gguf_get_tensor_offset(ctx, id);
    int tt = gguf_get_tensor_type(ctx, id);
    fprintf(stderr, "tensor '%s' type=%d offset=%zu\n", tname, tt, toff);
    printf("abs_off=%llu\n", (unsigned long long)(gguf_get_data_offset(ctx) + toff));
    gguf_free(ctx);
    return 0;
}
