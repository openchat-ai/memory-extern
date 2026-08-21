import shutil

p = "/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c"
shutil.copy(p, p + ".bak2")

with open(p) as f:
    c = f.read()

if "ggml_chip_set_threads" in c:
    print("already patched")
    raise SystemExit

c = c.replace("#include <signal.h>", "#include <signal.h>\n#include <semaphore.h>", 1)

hook_decl = """static int ggml_chip_hook_active(void);
static void ggml_chip_submit(const struct ggml_compute_params * params, const struct ggml_tensor * dst);
static void ggml_chip_wait_done(void);

static void ggml_compute_forward_mul_mat_id(
        const struct ggml_compute_params * params,
              struct ggml_tensor * dst) {

    if (ggml_chip_hook_active()) {
        if (params->ith == 0) {
            ggml_chip_submit(params, dst);
        }
        ggml_chip_wait_done();
        return;
    }
"""
anchor_fn = """static void ggml_compute_forward_mul_mat_id(
        const struct ggml_compute_params * params,
              struct ggml_tensor * dst) {
"""
assert anchor_fn in c, "mul_mat_id anchor not found"
c = c.replace(anchor_fn, hook_decl, 1)

module = r"""
// ================= chip coprocessor (simulated on-chip compute unit) =================
// Independent pthread pool that takes over GGML_OP_MUL_MAT_ID (MoE expert matmuls).
// ggml main threadpool blocks while the chip pool computes. No shared barriers.

#define GGML_CHIP_MAX_THREADS 16

static int ggml_chip_nthreads = 0;
static pthread_t ggml_chip_threads[GGML_CHIP_MAX_THREADS];
static sem_t ggml_chip_sem_submit;
static _Atomic int ggml_chip_pending;
static _Atomic int64_t ggml_chip_flops_total;
static _Atomic int64_t ggml_chip_bytes_total;
static _Atomic int64_t ggml_chip_ops_total;
static const struct ggml_tensor * ggml_chip_dst;
static const struct ggml_tensor * ggml_chip_src0;
static const struct ggml_tensor * ggml_chip_src1;
static const struct ggml_tensor * ggml_chip_ids;
static void * ggml_chip_wdata;

static int ggml_chip_hook_active(void) {
    return ggml_chip_nthreads > 0;
}

static void ggml_chip_run_op(int ith, int nth) {
    const struct ggml_tensor * dst  = ggml_chip_dst;
    const struct ggml_tensor * src0 = ggml_chip_src0;
    const struct ggml_tensor * src1 = ggml_chip_src1;
    const struct ggml_tensor * ids  = ggml_chip_ids;

    GGML_TENSOR_BINARY_OP_LOCALS

    const bool src1_cont = ggml_is_contiguous(src1);
    enum ggml_type const vec_dot_type = type_traits_cpu[src0->type].vec_dot_type;

    const int n_ids = ids->ne[0];
    const int n_as  = ne02;

    void * wdata_cur = ggml_chip_wdata;
    if (src1->type != vec_dot_type) {
        incr_ptr_aligned(&wdata_cur, ggml_row_size(vec_dot_type, ggml_nelements(src1)), sizeof(int64_t));
    }
    int64_t * matrix_row_counts = (int64_t *) incr_ptr_aligned(&wdata_cur, n_as*sizeof(int64_t), sizeof(int64_t));
    struct mmid_row_mapping * matrix_rows = (struct mmid_row_mapping *) incr_ptr_aligned(&wdata_cur, n_as*n_ids*ids->ne[1]*sizeof(struct mmid_row_mapping), sizeof(int64_t));
    char (*atomic_current_chunk)[CACHE_LINE_SIZE] = (char (*)[CACHE_LINE_SIZE]) incr_ptr_aligned(&wdata_cur, CACHE_LINE_SIZE * n_as, CACHE_LINE_SIZE);

    for (int cur_a = ith; cur_a < n_as; cur_a += nth) {
        atomic_int * current_chunk_ctr = (atomic_int *)(atomic_current_chunk + cur_a);
        *current_chunk_ctr = nth;
    }

    if (ith == 0) {
        memset(matrix_row_counts, 0, n_as*sizeof(int64_t));
        for (int64_t iid1 = 0; iid1 < ids->ne[1]; ++iid1) {
            for (int id = 0; id < n_ids; ++id) {
                const int32_t i02 = *(const int32_t *) ((const char *) ids->data + iid1*ids->nb[1] + id*ids->nb[0]);
                MMID_MATRIX_ROW(i02, matrix_row_counts[i02]) = (struct mmid_row_mapping) {id, iid1};
                matrix_row_counts[i02] += 1;
            }
        }
    }

    for (int cur_a = 0; cur_a < n_as; ++cur_a) {
        const int64_t cne1 = matrix_row_counts[cur_a];
        if (cne1 == 0) {
            continue;
        }
        atomic_fetch_add_explicit(&ggml_chip_flops_total, cne1 * ne01 * ne10 * 2, memory_order_relaxed);
        atomic_fetch_add_explicit(&ggml_chip_bytes_total, cne1 * nb02, memory_order_relaxed);

        const char * src0_cur = (const char *) src0->data + cur_a * nb02;
        const void * wdata = (src1->type == vec_dot_type) ? src1->data : ggml_chip_wdata;
        const size_t row_size = ggml_row_size(vec_dot_type, ne10);

        const int64_t nr0 = ne01;
        const int64_t nr1 = cne1;

        int chunk_size = 16;
        if (nr0 == 1 || nr1 == 1) {
            chunk_size = 64;
        }

        int64_t nchunk0 = (nr0 + chunk_size - 1) / chunk_size;
        int64_t nchunk1 = (nr1 + chunk_size - 1) / chunk_size;
        if (nchunk0 * nchunk1 < nth * 4) {
            nchunk0 = nr0 > nr1 ? nth : 1;
            nchunk1 = nr0 > nr1 ? 1 : nth;
        }

        const int64_t dr0 = (nr0 + nchunk0 - 1) / nchunk0;
        const int64_t dr1 = (nr1 + nchunk1 - 1) / nchunk1;

        int current_chunk = ith;
        atomic_int * current_chunk_ctr = (atomic_int *)(atomic_current_chunk + cur_a);

        while (current_chunk < nchunk0 * nchunk1) {
            const int64_t ith0 = current_chunk % nchunk0;
            const int64_t ith1 = current_chunk / nchunk0;

            const int64_t ir0_start = dr0 * ith0;
            const int64_t ir0_end = MIN(ir0_start + dr0, nr0);
            const int64_t ir1_start = dr1 * ith1;
            const int64_t ir1_end = MIN(ir1_start + dr1, nr1);

            ggml_compute_forward_mul_mat_id_one_chunk(
                (struct ggml_tensor *) dst, src0, src1, ids, cur_a,
                ir0_start, ir0_end, ir1_start, ir1_end,
                src0_cur, matrix_rows, row_size, src1_cont, wdata
            );

            if (nth >= nchunk0 * nchunk1) {
                break;
            }
            current_chunk = atomic_fetch_add_explicit(current_chunk_ctr, 1, memory_order_relaxed);
        }
    }
}

static void * ggml_chip_thread_main(void * arg) {
    const int ith = (int) (intptr_t) arg;
    for (;;) {
        sem_wait(&ggml_chip_sem_submit);
        ggml_chip_run_op(ith, ggml_chip_nthreads);
        atomic_fetch_sub_explicit(&ggml_chip_pending, 1, memory_order_release);
    }
    return NULL;
}

static void ggml_chip_submit(const struct ggml_compute_params * params, const struct ggml_tensor * dst) {
    const struct ggml_tensor * src0 = dst->src[0];
    const struct ggml_tensor * src1 = dst->src[1];
    const struct ggml_tensor * ids  = dst->src[2];

    GGML_TENSOR_BINARY_OP_LOCALS

    ggml_chip_dst  = dst;
    ggml_chip_src0 = src0;
    ggml_chip_src1 = src1;
    ggml_chip_ids  = ids;
    ggml_chip_wdata = params->wdata;

    const int n_ids = ids->ne[0];
    const int n_as  = ne02;

    enum ggml_type const vec_dot_type = type_traits_cpu[src0->type].vec_dot_type;
    ggml_from_float_t const from_float = type_traits_cpu[vec_dot_type].from_float;

    void * wdata_cur = params->wdata;
    if (src1->type != vec_dot_type) {
        incr_ptr_aligned(&wdata_cur, ggml_row_size(vec_dot_type, ggml_nelements(src1)), sizeof(int64_t));
    }
    incr_ptr_aligned(&wdata_cur, n_as*sizeof(int64_t), sizeof(int64_t));
    incr_ptr_aligned(&wdata_cur, n_as*n_ids*ids->ne[1]*sizeof(struct mmid_row_mapping), sizeof(int64_t));
    incr_ptr_aligned(&wdata_cur, CACHE_LINE_SIZE * n_as, CACHE_LINE_SIZE);

    if (src1->type != vec_dot_type) {
        char * wdata = params->wdata;
        const size_t nbw0 = ggml_type_size(vec_dot_type);
        const size_t nbw1 = ggml_row_size(vec_dot_type, ne10);
        const size_t nbw2 = nbw1*ne11;
        const size_t nbw3 = nbw2*ne12;
        GGML_ASSERT(src1->type == GGML_TYPE_F32);
        for (int64_t i13 = 0; i13 < ne13; ++i13) {
            for (int64_t i12 = 0; i12 < ne12; ++i12) {
                for (int64_t i11 = 0; i11 < ne11; ++i11) {
                    from_float((float *)((char *) src1->data + i13*nb13 + i12*nb12 + i11*nb11),
                               (void *)               (wdata + i13*nbw3 + i12*nbw2 + i11*nbw1),
                               ne10);
                }
            }
        }
    }

    atomic_store_explicit(&ggml_chip_pending, ggml_chip_nthreads, memory_order_release);
    atomic_fetch_add_explicit(&ggml_chip_ops_total, 1, memory_order_relaxed);
    for (int i = 0; i < ggml_chip_nthreads; i++) {
        sem_post(&ggml_chip_sem_submit);
    }
}

static void ggml_chip_wait_done(void) {
    while (atomic_load_explicit(&ggml_chip_pending, memory_order_acquire) != 0) {
        sched_yield();
    }
}

void ggml_chip_set_threads(int n) {
    if (n > GGML_CHIP_MAX_THREADS) {
        n = GGML_CHIP_MAX_THREADS;
    }
    if (n > 0 && ggml_chip_nthreads == 0) {
        sem_init(&ggml_chip_sem_submit, 0, 0);
        atomic_init(&ggml_chip_pending, 0);
        atomic_init(&ggml_chip_flops_total, 0);
        atomic_init(&ggml_chip_bytes_total, 0);
        atomic_init(&ggml_chip_ops_total, 0);
        for (int i = 0; i < n; i++) {
            pthread_create(&ggml_chip_threads[i], NULL, ggml_chip_thread_main, (void *) (intptr_t) i);
        }
    }
    ggml_chip_nthreads = n;
}

int ggml_chip_get_threads(void) {
    return ggml_chip_nthreads;
}

void ggml_chip_get_stats(int64_t * flops, int64_t * bytes, int64_t * ops) {
    *flops = atomic_load_explicit(&ggml_chip_flops_total, memory_order_relaxed);
    *bytes = atomic_load_explicit(&ggml_chip_bytes_total, memory_order_relaxed);
    *ops   = atomic_load_explicit(&ggml_chip_ops_total, memory_order_relaxed);
}

// ================== end chip coprocessor ==================

/////////////////////////////////
"""

anchor_mod = "/////////////////////////////////\n\nstatic void ggml_compute_forward(struct ggml_compute_params * params, struct ggml_tensor * tensor) {"
assert anchor_mod in c, "module anchor not found"
c = c.replace(anchor_mod, module + "\nstatic void ggml_compute_forward(struct ggml_compute_params * params, struct ggml_tensor * tensor) {", 1)

with open(p, "w") as f:
    f.write(c)
print("ggml-cpu.c patched")
