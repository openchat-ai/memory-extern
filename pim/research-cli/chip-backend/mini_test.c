#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <dlfcn.h>
#include "ggml.h"
#include "ggml-backend.h"
#include "ggml-backend-impl.h"

#define N_EMBD 256
#define N_FF 128
#define N_EXPERT 4
#define N_EXP_USED 2
#define N_TOK 3

static float frand(void) {
    return (float)((rand() % 2000 - 1000) / 1000.0);
}

int main(void) {
    void * h = dlopen("/tmp/chipbuild/libchip-backend.so", RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    int (*score)(void) = dlsym(h, "ggml_backend_score");
    ggml_backend_reg_t (*binit)(void) = dlsym(h, "ggml_backend_init");
    if (!score || !binit || score() != 1) { fprintf(stderr, "score/init fail\n"); return 1; }
    ggml_backend_reg_t reg = binit();
    ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, 0);
    printf("device=%s type=%d\n", ggml_backend_dev_name(dev), (int)ggml_backend_dev_type(dev));

    struct ggml_init_params ip = {
        /* .mem_size   = */ ggml_tensor_overhead()*32 + ggml_graph_overhead(),
        /* .mem_buffer = */ NULL,
        /* .no_alloc   = */ true,
    };
    struct ggml_context * ctx = ggml_init(ip);

    struct ggml_tensor * a = ggml_new_tensor_3d(ctx, GGML_TYPE_Q3_K, N_EMBD, N_FF, N_EXPERT);
    struct ggml_tensor * b = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, N_EMBD, N_EXP_USED, N_TOK);
    struct ggml_tensor * ids = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, N_EXP_USED, N_TOK);
    struct ggml_tensor * dst = ggml_mul_mat_id(ctx, a, b, ids);

    struct ggml_cgraph * graph = ggml_new_graph(ctx);
    ggml_build_forward_expand(graph, dst);

    size_t q3k_size = ggml_nbytes(a);
    void * a_data = malloc(q3k_size);
    float * ftmp = malloc(sizeof(float)*N_EMBD*N_FF*N_EXPERT);
    for (int i = 0; i < N_EMBD*N_FF*N_EXPERT; i++) ftmp[i] = frand();
    if (ggml_quantize_chunk(GGML_TYPE_Q3_K, ftmp, a_data, 0,
                            N_EXPERT*N_FF, N_EMBD, NULL) != (int)q3k_size) {
        fprintf(stderr, "quantize size mismatch\n"); return 1;
    }
    free(ftmp);

    ggml_backend_buffer_t buf = ggml_backend_alloc_ctx_tensors_from_buft(ctx, ggml_backend_cpu_buffer_type());
    (void)buf;
    memcpy(a->data, a_data, q3k_size);
    free(a_data);

    int32_t ids_data[N_EXP_USED*N_TOK];
    for (int t = 0; t < N_TOK; t++)
        for (int e = 0; e < N_EXP_USED; e++)
            ids_data[t*N_EXP_USED + e] = (t + e) % N_EXPERT;

    float b_data[N_EMBD*N_EXP_USED*N_TOK];
    for (int i = 0; i < N_EMBD*N_EXP_USED*N_TOK; i++) b_data[i] = frand();

    memcpy(ids->data, ids_data, sizeof(ids_data));
    memcpy(b->data, b_data, sizeof(b_data));

    ggml_backend_t (*cpu_init_fn)(void) = (ggml_backend_t (*)(void))dlsym(RTLD_DEFAULT, "ggml_backend_cpu_init");
    ggml_backend_t cpu = cpu_init_fn ? cpu_init_fn() : NULL;
    if (!cpu) { fprintf(stderr, "cpu init fail\n"); return 3; }
    enum ggml_status stc = ggml_backend_graph_compute(cpu, graph);
    printf("cpu compute status=%d (%s)\n", (int)stc, ggml_status_to_string(stc));
    if (stc != GGML_STATUS_SUCCESS) return 4;
    float ref[N_FF*N_EXP_USED*N_TOK];
    memcpy(ref, dst->data, sizeof(ref));

    memcpy(b->data, b_data, sizeof(b_data));
    memcpy(ids->data, ids_data, sizeof(ids_data));

    ggml_backend_t chip = ggml_backend_dev_init(dev, NULL);
    enum ggml_status st = ggml_backend_graph_compute(chip, graph);
    printf("chip compute status=%d (%s)\n", (int)st, ggml_status_to_string(st));
    if (st != GGML_STATUS_SUCCESS) return 5;

    double max_err = 0;
    for (int i = 0; i < N_FF*N_EXP_USED*N_TOK; i++) {
        double e = fabs(((float*)dst->data)[i] - ref[i]);
        if (e > max_err) max_err = e;
    }
    printf("max_abs_err=%g\n", max_err);
    int rc = max_err <= 1.0 ? 0 : 6;
    printf("%s\n", rc == 0 ? "MATCH" : "MISMATCH");
    return rc;
}
