#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "ggml.h"
#include "ggml-cpu.h"

extern void ggml_chip_set_threads(int n);
extern void ggml_chip_set_nt_copy(int v);

#define N_AS 6
#define NE00 64
#define NE01 32
#define N_TOK 5
#define N_ID 8

static float dst_ref[N_ID * N_TOK * NE01];
static float dst_cur[N_ID * N_TOK * NE01];

int main(int argc, char ** argv) {
    struct ggml_init_params ip = {
        .mem_size = 64 * 1024 * 1024,
        .mem_buffer = NULL,
        .no_alloc = 0,
    };
    struct ggml_context * ctx = ggml_init(ip);

    struct ggml_tensor * src0 = ggml_new_tensor_3d(ctx, GGML_TYPE_F16, NE00, NE01, N_AS);
    struct ggml_tensor * src1 = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, NE00, N_ID, N_TOK);
    struct ggml_tensor * ids = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, N_ID, N_TOK);

    srand(1234);
    const int ne00 = ggml_nelements(src0);
    ggml_fp16_t * d0 = (ggml_fp16_t *) src0->data;
    for (int i = 0; i < ne00; ++i) {
        d0[i] = ggml_fp32_to_fp16(((float) rand() / RAND_MAX - 0.5f));
    }
    float * d1 = (float *) src1->data;
    for (int i = 0; i < NE00 * N_ID * N_TOK; ++i) {
        d1[i] = (float) rand() / RAND_MAX - 0.5f;
    }
    int32_t * di = (int32_t *) ids->data;
    for (int i = 0; i < N_ID * N_TOK; ++i) {
        di[i] = rand() % N_AS;
    }

    struct ggml_tensor * out = ggml_mul_mat_id(ctx, src0, src1, ids);

    struct ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, out);

    const int n_threads = 4;

    ggml_chip_set_threads(0);
    ggml_graph_compute_with_ctx(ctx, gf, n_threads);
    memcpy(dst_ref, out->data, sizeof(dst_ref));

    int nchip = argc > 1 ? atoi(argv[1]) : n_threads;
    {
        for (int rep = 0; rep < 3; ++rep) {
            memset(out->data, 0, ggml_nbytes(out));
            ggml_chip_set_threads(nchip);
            ggml_graph_compute_with_ctx(ctx, gf, n_threads);
            memcpy(dst_cur, out->data, sizeof(dst_cur));

            double max_diff = 0.0;
            int bad = -1;
            int zeros = 0;
            for (int i = 0; i < N_ID * N_TOK * NE01; ++i) {
                double diff = fabs((double) dst_ref[i] - (double) dst_cur[i]);
                if (diff > max_diff) {
                    max_diff = diff;
                }
                if (diff > 1e-2 && bad < 0) {
                    bad = i;
                }
                if (fabs((double) dst_cur[i]) < 1e-30) {
                    ++zeros;
                }
            }
            printf("nchip=%d rep %d: max_abs_diff=%.6f bad_cells=%d zeros=%d/%d", nchip, rep,
                max_diff, max_diff > 1e-2, zeros, N_ID * N_TOK * NE01);
            if (bad >= 0) {
                printf(" first_bad=%d ref=%.4f got=%.4f", bad, dst_ref[bad], dst_cur[bad]);
            }
            printf("\n");
            {
                int miss_per_exp[N_AS] = {0};
                for (int t = 0; t < N_TOK; ++t) {
                    for (int s = 0; s < N_ID; ++s) {
                        int e = ((int32_t *) ids->data)[s + t * N_ID];
                        for (int r = 0; r < NE01; ++r) {
                            int idx = r + NE01 * (s + N_ID * t);
                            if (fabs((double) dst_cur[idx]) < 1e-30 &&
                                fabs((double) dst_ref[idx]) > 1e-6) {
                                ++miss_per_exp[e];
                            }
                        }
                    }
                }
                printf("  per-expert missing:");
                for (int e = 0; e < N_AS; ++e) {
                    printf(" e%d=%d", e, miss_per_exp[e]);
                }
                printf("\n");
            }
        }
    }

    ggml_chip_set_threads(0);
    ggml_chip_set_nt_copy(1);
    {
        memset(out->data, 0, ggml_nbytes(out));
        ggml_chip_set_threads(nchip);
        ggml_graph_compute_with_ctx(ctx, gf, n_threads);
        memcpy(dst_cur, out->data, sizeof(dst_cur));

        double max_diff = 0.0;
        for (int i = 0; i < N_ID * N_TOK * NE01; ++i) {
            double diff = fabs((double) dst_ref[i] - (double) dst_cur[i]);
            if (diff > max_diff) {
                max_diff = diff;
            }
        }
        printf("nchip=%d nt=1: max_abs_diff=%.6f\n", nchip, max_diff);
    }

    ggml_chip_set_threads(0);
    ggml_chip_set_nt_copy(0);
    ggml_free(ctx);
    return 0;
}
