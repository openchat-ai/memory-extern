/* gguf_dump.c — 打印 GGUF 全部张量：类型分布 + 前若干张量名/形状/offset。
 * 用于确认 requant 注入需要支持的量化类型全集。 */
#include "ggml.h"
#include "gguf.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: %s <model.gguf>\n", argv[0]); return 2; }
    struct gguf_init_params params = { .no_alloc = true, .ctx = NULL };
    struct gguf_context *ctx = gguf_init_from_file(argv[1], params);
    if (!ctx) { fprintf(stderr, "gguf_init failed: %s\n", argv[1]); return 2; }

    const int nt = gguf_get_n_tensors(ctx);
    const uint64_t data_off = gguf_get_data_offset(ctx);
    printf("n_kv=%d n_tensors=%d data_offset=%" PRIu64 "\n",
           gguf_get_n_kv(ctx), nt, data_off);

    int ntypes[GGML_TYPE_COUNT] = {0};
    for (int i = 0; i < nt; i++) {
        int t = gguf_get_tensor_type(ctx, i);
        if (t >= 0 && t < GGML_TYPE_COUNT) ntypes[t]++;
    }
    printf("type distribution:\n");
    for (int t = 0; t < GGML_TYPE_COUNT; t++) {
        if (ntypes[t]) printf("  %-12s %6d\n", ggml_type_name(t), ntypes[t]);
    }

    printf("\nfirst 60 tensors:\n");
    for (int i = 0; i < nt && i < 60; i++) {
        printf("  %-50s %-10s size=%-8zu off=%" PRIu64 "\n",
               gguf_get_tensor_name(ctx, i),
               ggml_type_name(gguf_get_tensor_type(ctx, i)),
               gguf_get_tensor_size(ctx, i),
               gguf_get_tensor_offset(ctx, i));
    }
    printf("\nlast 10 tensors:\n");
    for (int i = nt > 10 ? nt - 10 : 0; i < nt; i++) {
        printf("  %-50s %-10s off=%" PRIu64 "\n",
               gguf_get_tensor_name(ctx, i),
               ggml_type_name(gguf_get_tensor_type(ctx, i)),
               gguf_get_tensor_offset(ctx, i));
    }
    gguf_free(ctx);
    return 0;
}
