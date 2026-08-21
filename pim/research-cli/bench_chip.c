#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include "ggml.h"
#include "ggml-cpu.h"

extern void ggml_chip_set_threads(int n);
extern int  ggml_chip_get_threads(void);
extern void ggml_chip_set_sync_mode(int m);
extern void ggml_chip_set_copy_only(int v);
extern void ggml_chip_set_nt_copy(int v);
extern void ggml_chip_get_stats(int64_t * flops, int64_t * bytes, int64_t * ops);
extern void ggml_chip_get_breakdown(int64_t * copy_ns, int64_t * copy_bytes, int64_t * compute_ns);

#define NE00 2048
#define NE01 512
#define N_AS 256
#define N_ID 8
#define N_TOK 4

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double) ts.tv_sec + (double) ts.tv_nsec * 1e-9;
}

int main(int argc, char ** argv) {
    const int n_tokens = argc > 1 ? atoi(argv[1]) : N_TOK;
    const int n_rep    = argc > 2 ? atoi(argv[2]) : 200;
    const int nt_enable = argc > 3 ? atoi(argv[3]) : 0;
    ggml_chip_set_nt_copy(nt_enable);

    struct ggml_init_params ip = {
        .mem_size = 1u << 30,
        .mem_buffer = NULL,
        .no_alloc = 0,
    };
    struct ggml_context * ctx = ggml_init(ip);

    struct ggml_tensor * src0 = ggml_new_tensor_3d(ctx, GGML_TYPE_Q3_K, NE00, NE01, N_AS);
    struct ggml_tensor * src1 = ggml_new_tensor_3d(ctx, GGML_TYPE_F32, NE00, N_ID, n_tokens);
    struct ggml_tensor * ids  = ggml_new_tensor_2d(ctx, GGML_TYPE_I32, N_ID, n_tokens);

    srand(1234);
    for (size_t i = 0; i < ggml_nbytes(src0); ++i) {
        ((uint8_t *) src0->data)[i] = (uint8_t) rand();
    }
    float * d1 = (float *) src1->data;
    fprintf(stderr, "fill src1 %p ne=%zu nbytes=%zu\n", (void*)src1->data, ggml_nelements(src1), ggml_nbytes(src1));
    for (int i = 0; i < ggml_nelements(src1); ++i) {
        d1[i] = (float) rand() / RAND_MAX - 0.5f;
    }
    int32_t * di = (int32_t *) ids->data;
    for (int i = 0; i < ggml_nelements(ids); ++i) {
        di[i] = rand() % N_AS;
    }
    fprintf(stderr, "setup done\n");

    struct ggml_tensor * out = ggml_mul_mat_id(ctx, src0, src1, ids);
    struct ggml_cgraph * gf = ggml_new_graph(ctx);
    ggml_build_forward_expand(gf, out);
    fprintf(stderr, "graph built out=%p gf=%p\n", (void*)out, (void*)gf);

    const int64_t flops_per_run = 2LL * NE00 * NE01 * N_ID * n_tokens;

    ggml_chip_set_threads(0);
    ggml_graph_compute_with_ctx(ctx, gf, 4);

    const int configs[] = {0, 1, 2, 4, 8, 16};
    for (int ci = 0; ci < 6; ++ci) {
        const int nchip = configs[ci];
        ggml_chip_set_threads(nchip);

        ggml_chip_set_sync_mode(1);
        for (int w = 0; w < 3; ++w) {
            ggml_graph_compute_with_ctx(ctx, gf, 4);
        }
        int64_t pf0 = 0, pb0 = 0, po0 = 0;
        ggml_chip_get_stats(&pf0, &pb0, &po0);
        double t0 = now_s();
        for (int r = 0; r < n_rep; ++r) {
            ggml_graph_compute_with_ctx(ctx, gf, 4);
        }
        double dt = now_s() - t0;

        int64_t flops = 0, bytes = 0, ops = 0;
        ggml_chip_get_stats(&flops, &bytes, &ops);
        flops -= pf0; bytes -= pb0; ops -= po0;

        double gflops = flops_per_run * n_rep / dt / 1e9;
        printf("nchip=%-2d n_tok=%d n_rep=%d: %.4fs -> %.2f GFLOPS  (%.1f tok/s at %.0f MB/tok)\n",
            nchip, n_tokens, n_rep, dt, gflops, n_rep / dt, 0.0);

        if (nchip > 0) {
            int64_t cn0 = 0, cb0 = 0, cmp0 = 0;
            ggml_chip_get_breakdown(&cn0, &cb0, &cmp0);

            ggml_chip_set_sync_mode(0);
            for (int w = 0; w < 3; ++w) {
                ggml_graph_compute_with_ctx(ctx, gf, 4);
            }
            int64_t cf0 = 0, cc0 = 0, co0 = 0, ccn0 = 0, ccb0 = 0, ccmp0 = 0;
            ggml_chip_get_stats(&cf0, &cc0, &co0);
            ggml_chip_get_breakdown(&ccn0, &ccb0, &ccmp0);
            double tc0 = now_s();
            for (int r = 0; r < n_rep; ++r) {
                ggml_graph_compute_with_ctx(ctx, gf, 4);
            }
            double dtc = now_s() - tc0;
            int64_t cflops = 0, cbytes = 0, cops = 0;
            int64_t ccopy_ns = 0, ccopy_bytes = 0, ccomp_ns = 0;
            ggml_chip_get_stats(&cflops, &cbytes, &cops);
            ggml_chip_get_breakdown(&ccopy_ns, &ccopy_bytes, &ccomp_ns);
            cflops -= cf0; cbytes -= cc0; cops -= co0;
            ccopy_ns -= ccn0; ccopy_bytes -= ccb0; ccomp_ns -= ccmp0;

            double copy_gbs = ccopy_bytes / 1e9 / (ccopy_ns / 1e9);
            double comp_gflops = flops_per_run * n_rep / (ccomp_ns / 1e9) / 1e9;
            printf("   barrier: copy %.3f ms %.2f GiB/s | compute %.3f ms %.2f GFLOPS | total %.4fs\n",
                ccopy_ns / 1e6, copy_gbs, ccomp_ns / 1e6, comp_gflops, dtc);

            ggml_chip_set_copy_only(1);
            for (int w = 0; w < 3; ++w) {
                ggml_graph_compute_with_ctx(ctx, gf, 4);
            }
            int64_t x0 = 0, y0 = 0;
            ggml_chip_get_breakdown(&x0, &y0, &ccmp0);
            double tx0 = now_s();
            for (int r = 0; r < n_rep; ++r) {
                ggml_graph_compute_with_ctx(ctx, gf, 4);
            }
            double dtx = now_s() - tx0;
            int64_t xcopy_ns = 0, xcopy_bytes = 0, xcomp_ns = 0;
            ggml_chip_get_breakdown(&xcopy_ns, &xcopy_bytes, &xcomp_ns);
            xcopy_ns -= x0; xcopy_bytes -= y0;
            double xcopy_gbs = xcopy_bytes / 1e9 / (xcopy_ns / 1e9);
            printf("   copy-only: %.3f ms %.2f GiB/s | wall %.4fs\n",
                xcopy_ns / 1e6, xcopy_gbs, dtx);
            ggml_chip_set_copy_only(0);
        }
        ggml_chip_set_threads(0);
    }

    ggml_chip_set_threads(0);
    ggml_free(ctx);
    return 0;
}