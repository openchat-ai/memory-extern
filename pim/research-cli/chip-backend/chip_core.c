#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <semaphore.h>
#include <sched.h>
#include <time.h>
#include <unistd.h>
#include <dlfcn.h>
#ifdef __x86_64__
#include <immintrin.h>
#endif

#include "ggml.h"
#include "ggml-backend.h"
#include "chip_core.h"

#define CHIP_MAX_THREADS 16
#define CACHE_LINE_SIZE 64

typedef void (*chip_from_float_fn)(const float * x, void * y, int64_t k);

int chip_log_level(void) {
    static int lvl = -1;
    if (lvl < 0) {
        const char * e = getenv("CHIP_LOG_LEVEL");
        lvl = e ? atoi(e) : 1;
        if (lvl < 0) lvl = 0;
    }
    return lvl;
}

#define CHIP_LOG(...) do { if (chip_log_level() >= 1) { fprintf(stderr, "[chip-core] " __VA_ARGS__); } } while (0)

int chip_nchips(void) {
    static int v = -1;
    if (v < 0) {
        const char * e = getenv("CHIP_NCHIPS");
        v = e ? atoi(e) : 16;
        if (v <= 0) v = 16;
    }
    return v;
}

int chip_nworkers(void) {
    static int v = -1;
    if (v < 0) {
        const char * e = getenv("CHIP_NWORKERS");
        v = e ? atoi(e) : 4;
        if (v <= 0) v = 4;
        if (v > CHIP_MAX_THREADS) v = CHIP_MAX_THREADS;
    }
    return v;
}

int chip_nt_copy(void) {
    static int v = -1;
    if (v < 0) {
        const char * e = getenv("CHIP_NT_COPY");
        v = e ? atoi(e) : 2;
        if (v < 0) v = 0;
    }
    return v;
}

static chip_vec_dot_fn chip_vec_dot_tab[4]; /* Q3_K, IQ3_XXS, IQ3_S, IQ4_XS */
static chip_vec_dot_fn chip_vec_dot_cur;
static chip_from_float_fn chip_from_float;

static chip_vec_dot_fn chip_vec_dot_for(enum ggml_type t) {
    switch (t) {
        case GGML_TYPE_Q3_K:    return chip_vec_dot_tab[0];
        case GGML_TYPE_IQ3_XXS: return chip_vec_dot_tab[1];
        case GGML_TYPE_IQ3_S:   return chip_vec_dot_tab[2];
        case GGML_TYPE_IQ4_XS:  return chip_vec_dot_tab[3];
        default:                return NULL;
    }
}

struct mmid_row_mapping {
    int32_t i1;
    int32_t i2;
};

#define CHIP_MMID_MATRIX_ROW(row_id, i1) matrix_rows[(row_id)*ids->ne[0]*ids->ne[1] + (i1)]

#define CHIP_TENSOR_OP_LOCALS \
    const int64_t ne00=src0->ne[0]; \
    const int64_t ne01=src0->ne[1]; \
    const int64_t ne02=src0->ne[2]; \
    const size_t  nb01=src0->nb[1]; \
    const size_t  nb02=src0->nb[2]; \
    const int64_t ne10=src1->ne[0]; \
    const int64_t ne11=src1->ne[1]; \
    const int64_t ne12=src1->ne[2]; \
    const int64_t ne13=src1->ne[3]; \
    const size_t  nb11=src1->nb[1]; \
    const size_t  nb12=src1->nb[2]; \
    const size_t  nb13=src1->nb[3];

#define GGML_CHIP_MAX_THREADS CHIP_MAX_THREADS

static int ggml_chip_nthreads = 0;
static pthread_t ggml_chip_threads[GGML_CHIP_MAX_THREADS];
static sem_t ggml_chip_sem_submit[GGML_CHIP_MAX_THREADS];
static pthread_mutex_t ggml_chip_done_mtx;
static pthread_cond_t ggml_chip_done_cv;
static _Atomic int ggml_chip_pending;
static _Atomic int64_t ggml_chip_flops_total;
static _Atomic int64_t ggml_chip_bytes_total;
static _Atomic int64_t ggml_chip_ops_total;
static const struct ggml_tensor * ggml_chip_dst;
static const struct ggml_tensor * ggml_chip_src0;
static const struct ggml_tensor * ggml_chip_src1;
static const struct ggml_tensor * ggml_chip_ids;
static void * ggml_chip_wdata;

static void * ggml_chip_sram = NULL;
static size_t ggml_chip_sram_cap = 0;
static int64_t * ggml_chip_sram_off = NULL;
static int64_t ggml_chip_sram_off_cap = 0;
static int ggml_chip_zcopy = 1;
static _Atomic int64_t ggml_chip_copy_ns_total;
static _Atomic int64_t ggml_chip_copy_bytes_total;
static _Atomic int64_t ggml_chip_compute_ns_total;
static _Atomic int ggml_chip_copy_left;
static _Atomic int ggml_chip_copy_done;
static _Atomic int ggml_chip_copy_started;
static _Atomic int ggml_chip_copy_next;
static _Atomic int64_t ggml_chip_copy_t0_ns;
static _Atomic int64_t ggml_chip_copy_t1_ns;
static _Atomic int64_t ggml_chip_comp_t0_ns;
static _Atomic int ggml_chip_comp_started;
static _Atomic int ggml_chip_sync_mode;
static _Atomic int64_t ggml_chip_chunks_left;
static _Atomic int ggml_chip_copy_only;
static _Atomic int * ggml_chip_expert_ready = NULL;
static size_t ggml_chip_expert_ready_cap = 0;

static _Atomic int ggml_chip_nt_copy;

static void * ggml_chip_scratch = NULL;
static size_t ggml_chip_scratch_cap = 0;

static void * ggml_chip_sram_aligned_realloc(void * ptr, size_t old_cap, size_t new_cap) {
    if (ptr == NULL) {
        void * p = NULL;
        if (posix_memalign(&p, 64, new_cap) != 0) {
            return NULL;
        }
        return p;
    }
    void * p = NULL;
    if (posix_memalign(&p, 64, new_cap) != 0) {
        return NULL;
    }
    memcpy(p, ptr, old_cap);
    free(ptr);
    return p;
}

#ifdef __x86_64__
static void ggml_chip_nt_memcpy(void * dst, const void * src, size_t n) {
    if (((uintptr_t) dst & 31) != 0) {
        memcpy(dst, src, n);
        return;
    }
    unsigned char * d = (unsigned char *) dst;
    const unsigned char * s = (const unsigned char *) src;
    size_t i = 0;
    for (; i + 64 <= n; i += 64) {
        __m256i a = _mm256_loadu_si256((const __m256i *)(s + i));
        __m256i b = _mm256_loadu_si256((const __m256i *)(s + i + 32));
        _mm256_stream_si256((__m256i *)(d + i), a);
        _mm256_stream_si256((__m256i *)(d + i + 32), b);
    }
    for (; i < n; i++) {
        d[i] = s[i];
    }
    _mm_sfence();
}
#endif

static void * incr_ptr_aligned(void ** p, size_t size, size_t align) {
    void * ptr = *p;
    ptr = (void *) (((uintptr_t) ptr + align - 1) & ~(uintptr_t)(align - 1));
    *p = (void *) ((char *) ptr + size);
    return ptr;
}

static void ggml_compute_forward_mul_mat_id_one_chunk(
    struct ggml_tensor * dst,
    const struct ggml_tensor * src0,
    const struct ggml_tensor * src1,
    const struct ggml_tensor * ids,
    const int64_t cur_a,
    const int64_t ir0_start,
    const int64_t ir0_end,
    const int64_t ir1_start,
    const int64_t ir1_end,
    const char * src0_cur,
    const struct mmid_row_mapping * matrix_rows,
    const size_t row_size,
    const bool src1_cont,
    const void * wdata) {

    CHIP_TENSOR_OP_LOCALS

    const size_t nb1 = dst->nb[1];
    const size_t nb2 = dst->nb[2];

    chip_vec_dot_fn const vec_dot = chip_vec_dot_cur;
    enum ggml_type const vec_dot_type = GGML_TYPE_Q8_K;

    const int64_t blck_0 = 16;
    const int64_t blck_1 = 16;

    float tmp[16];

    for (int64_t iir1 = ir1_start; iir1 < ir1_end; iir1 += blck_1) {
        for (int64_t iir0 = ir0_start; iir0 < ir0_end; iir0 += blck_0) {
            for (int64_t ir1 = iir1; ir1 < iir1 + blck_1 && ir1 < ir1_end; ++ir1) {
                const int64_t _i12 = ir1;

                struct mmid_row_mapping row_mapping = CHIP_MMID_MATRIX_ROW(cur_a, _i12);
                const int id       = row_mapping.i1;

                const int64_t  i11 = id % ne11;
                const int64_t  i12 = row_mapping.i2;

                const int64_t  i1 = id;
                const int64_t  i2 = i12;

                const char * src1_col = (const char *) wdata +
                    (src1_cont || src1->type != vec_dot_type
                    ? (i11      + i12*ne11)*row_size
                    : (i11*nb11 + i12*nb12));

                float * dst_col = (float *) ((char *) dst->data + (i1*nb1 + i2*nb2));

                for (int64_t ir0 = iir0; ir0 < iir0 + blck_0 && ir0 < ir0_end; ++ir0) {
                    vec_dot(ne00, &tmp[ir0 - iir0], 0, src0_cur + ir0*nb01, 0, src1_col, 0, 1);
                }

                memcpy(&dst_col[iir0], tmp, ((iir0 + blck_0 < ir0_end ? iir0 + blck_0 : ir0_end) - iir0)*sizeof(float));
            }
        }
    }
}

static void ggml_chip_run_op(int ith, int nth);

static void * ggml_chip_thread_main(void * arg) {
    const int ith = (int) (intptr_t) arg;
    for (;;) {
        sem_wait(&ggml_chip_sem_submit[ith]);
        ggml_chip_run_op(ith, ggml_chip_nthreads);
        pthread_mutex_lock(&ggml_chip_done_mtx);
        if (atomic_fetch_sub_explicit(&ggml_chip_pending, 1, memory_order_release) == 1) {
            struct timespec te;
            clock_gettime(CLOCK_MONOTONIC, &te);
            atomic_fetch_add_explicit(&ggml_chip_compute_ns_total,
                ((int64_t) te.tv_sec * 1000000000LL + te.tv_nsec) -
                atomic_load_explicit(&ggml_chip_comp_t0_ns, memory_order_relaxed), memory_order_relaxed);
            pthread_cond_broadcast(&ggml_chip_done_cv);
        }
        pthread_mutex_unlock(&ggml_chip_done_mtx);
    }
    return NULL;
}

static void ggml_chip_run_op(int ith, int nth) {
    const struct ggml_tensor * dst  = ggml_chip_dst;
    const struct ggml_tensor * src0 = ggml_chip_src0;
    const struct ggml_tensor * src1 = ggml_chip_src1;
    const struct ggml_tensor * ids  = ggml_chip_ids;

    CHIP_TENSOR_OP_LOCALS

    const bool src1_cont = ggml_is_contiguous(src1);

    const int n_ids = ids->ne[0];
    const int n_as  = ne02;

    void * wdata_cur = ggml_chip_wdata;
    if (src1->type != GGML_TYPE_Q8_K) {
        incr_ptr_aligned(&wdata_cur, ggml_row_size(GGML_TYPE_Q8_K, ggml_nelements(src1)), sizeof(int64_t));
    }
    int64_t * matrix_row_counts = (int64_t *) incr_ptr_aligned(&wdata_cur, n_as*sizeof(int64_t), sizeof(int64_t));
    struct mmid_row_mapping * matrix_rows = (struct mmid_row_mapping *) incr_ptr_aligned(&wdata_cur, n_as*n_ids*ids->ne[1]*sizeof(struct mmid_row_mapping), sizeof(int64_t));
    char (*atomic_current_chunk)[CACHE_LINE_SIZE] = (char (*)[CACHE_LINE_SIZE]) incr_ptr_aligned(&wdata_cur, CACHE_LINE_SIZE * n_as, CACHE_LINE_SIZE);

    const size_t exp_bytes = (size_t) ne01 * nb01;

    struct timespec cpy0, cpy1;
    int64_t copied = 0;
    if (atomic_exchange_explicit(&ggml_chip_copy_started, 1, memory_order_relaxed) == 0) {
        clock_gettime(CLOCK_MONOTONIC, &cpy0);
        atomic_store_explicit(&ggml_chip_copy_t0_ns,
            (int64_t) cpy0.tv_sec * 1000000000LL + cpy0.tv_nsec, memory_order_relaxed);
    }
    for (;;) {
        const int cur_a = atomic_fetch_add_explicit(&ggml_chip_copy_next, 1, memory_order_relaxed);
        if (cur_a >= n_as) {
            break;
        }
        if (matrix_row_counts[cur_a] <= 0) {
            continue;
        }
        if (!ggml_chip_zcopy) {
#ifdef __x86_64__
            if (atomic_load_explicit(&ggml_chip_nt_copy, memory_order_relaxed) != 0) {
                ggml_chip_nt_memcpy((char *) ggml_chip_sram + ggml_chip_sram_off[cur_a],
                                    (const char *) src0->data + cur_a * nb02, exp_bytes);
            } else
#endif
            {
                memcpy((char *) ggml_chip_sram + ggml_chip_sram_off[cur_a],
                       (const char *) src0->data + cur_a * nb02, exp_bytes);
            }
        }
        copied += (int64_t) exp_bytes;
        atomic_store_explicit(&ggml_chip_expert_ready[cur_a], 1, memory_order_release);
    }
    atomic_fetch_add_explicit(&ggml_chip_copy_bytes_total, copied, memory_order_relaxed);
    if (atomic_fetch_sub_explicit(&ggml_chip_copy_left, 1, memory_order_relaxed) == 1) {
        clock_gettime(CLOCK_MONOTONIC, &cpy1);
        atomic_store_explicit(&ggml_chip_copy_t1_ns,
            (int64_t) cpy1.tv_sec * 1000000000LL + cpy1.tv_nsec, memory_order_relaxed);
        atomic_fetch_add_explicit(&ggml_chip_copy_ns_total,
            atomic_load_explicit(&ggml_chip_copy_t1_ns, memory_order_relaxed) -
            atomic_load_explicit(&ggml_chip_copy_t0_ns, memory_order_relaxed), memory_order_relaxed);
        atomic_store_explicit(&ggml_chip_copy_done, 1, memory_order_release);
    }

    for (;;) {
        if (atomic_load_explicit(&ggml_chip_sync_mode, memory_order_relaxed) == 0) {
            while (atomic_load_explicit(&ggml_chip_copy_done, memory_order_acquire) == 0) {
                sched_yield();
            }
        }
        if (atomic_load_explicit(&ggml_chip_copy_only, memory_order_relaxed) != 0) {
            return;
        }
        bool any_work = false;
        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            const int64_t cne1 = matrix_row_counts[cur_a];
            if (cne1 == 0) {
                continue;
            }
            if (atomic_load_explicit(&ggml_chip_expert_ready[cur_a], memory_order_acquire) == 0) {
                continue;
            }
            if (atomic_exchange_explicit(&ggml_chip_comp_started, 1, memory_order_relaxed) == 0) {
                struct timespec cps;
                clock_gettime(CLOCK_MONOTONIC, &cps);
                atomic_store_explicit(&ggml_chip_comp_t0_ns,
                    (int64_t) cps.tv_sec * 1000000000LL + cps.tv_nsec, memory_order_relaxed);
            }
            const char * src0_cur = ggml_chip_zcopy
                ? (const char *) src0->data + (size_t) cur_a * nb02
                : (const char *) ggml_chip_sram + ggml_chip_sram_off[cur_a];
            const void * wdata = (src1->type == GGML_TYPE_Q8_K) ? src1->data : ggml_chip_wdata;
            const size_t row_size = ggml_row_size(GGML_TYPE_Q8_K, ne10);

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

            atomic_int * current_chunk_ctr = (atomic_int *)(atomic_current_chunk + cur_a);
            int current_chunk = atomic_fetch_add_explicit(current_chunk_ctr, 1, memory_order_relaxed);

            while (current_chunk < nchunk0 * nchunk1) {
                const int64_t ith0 = current_chunk % nchunk0;
                const int64_t ith1 = current_chunk / nchunk0;

                const int64_t ir0_start = dr0 * ith0;
                const int64_t ir0_end = (ir0_start + dr0 < nr0 ? ir0_start + dr0 : nr0);
                const int64_t ir1_start = dr1 * ith1;
                const int64_t ir1_end = (ir1_start + dr1 < nr1 ? ir1_start + dr1 : nr1);

                ggml_compute_forward_mul_mat_id_one_chunk(
                    (struct ggml_tensor *) dst, src0, src1, ids, cur_a,
                    ir0_start, ir0_end, ir1_start, ir1_end,
                    src0_cur, matrix_rows, row_size, src1_cont, wdata
                );
                atomic_fetch_sub_explicit(&ggml_chip_chunks_left, 1, memory_order_release);
                any_work = true;

                current_chunk = atomic_fetch_add_explicit(current_chunk_ctr, 1, memory_order_relaxed);
            }
        }
        if (any_work) {
            continue;
        }
        if (atomic_load_explicit(&ggml_chip_chunks_left, memory_order_acquire) == 0) {
            break;
        }
        sched_yield();
    }
}

static void ggml_chip_submit(const struct ggml_tensor * dst) {
    const struct ggml_tensor * src0 = dst->src[0];
    const struct ggml_tensor * src1 = dst->src[1];
    const struct ggml_tensor * ids  = dst->src[2];

    CHIP_TENSOR_OP_LOCALS

    ggml_chip_dst  = dst;
    ggml_chip_src0 = src0;
    ggml_chip_src1 = src1;
    ggml_chip_ids  = ids;

    const int n_ids = ids->ne[0];
    const int n_as  = ne02;

    size_t scratch_need = 0;
    if (src1->type != GGML_TYPE_Q8_K) {
        scratch_need += ggml_row_size(GGML_TYPE_Q8_K, ggml_nelements(src1));
    }
    scratch_need += n_as*sizeof(int64_t);
    scratch_need += (size_t)n_as*n_ids*ids->ne[1]*sizeof(struct mmid_row_mapping);
    scratch_need += CACHE_LINE_SIZE * n_as;
    scratch_need += 64;
    if (ggml_chip_scratch_cap < scratch_need) {
        free(ggml_chip_scratch);
        ggml_chip_scratch = malloc(scratch_need);
        ggml_chip_scratch_cap = scratch_need;
    }
    ggml_chip_wdata = ggml_chip_scratch;

    if (src1->type != GGML_TYPE_Q8_K) {
        char * wdata = ggml_chip_wdata;

        const size_t nbw1 = ggml_row_size(GGML_TYPE_Q8_K, ne10);
        const size_t nbw2 = nbw1*ne11;
        const size_t nbw3 = nbw2*ne12;

        for (int64_t i13 = 0; i13 < ne13; ++i13) {
            for (int64_t i12 = 0; i12 < ne12; ++i12) {
                for (int64_t i11 = 0; i11 < ne11; ++i11) {
                    chip_from_float((float *)((char *) src1->data + i13*nb13 + i12*nb12 + i11*nb11),
                               (void *)               (wdata + i13*nbw3 + i12*nbw2 + i11*nbw1),
                               ne10);
                }
            }
        }
    }

    {
        void * wd = ggml_chip_wdata;
        if (src1->type != GGML_TYPE_Q8_K) {
            incr_ptr_aligned(&wd, ggml_row_size(GGML_TYPE_Q8_K, ggml_nelements(src1)), sizeof(int64_t));
        }
        int64_t * matrix_row_counts = (int64_t *) incr_ptr_aligned(&wd, n_as*sizeof(int64_t), sizeof(int64_t));
        struct mmid_row_mapping * matrix_rows = (struct mmid_row_mapping *) incr_ptr_aligned(&wd, n_as*n_ids*ids->ne[1]*sizeof(struct mmid_row_mapping), sizeof(int64_t));
        char (*atomic_current_chunk)[CACHE_LINE_SIZE] = (char (*)[CACHE_LINE_SIZE]) incr_ptr_aligned(&wd, CACHE_LINE_SIZE * n_as, CACHE_LINE_SIZE);

        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            atomic_int * current_chunk_ctr = (atomic_int *)(atomic_current_chunk + cur_a);
            *current_chunk_ctr = 0;
        }
        memset(matrix_row_counts, 0, n_as*sizeof(int64_t));
        for (int64_t iid1 = 0; iid1 < ids->ne[1]; ++iid1) {
            for (int id = 0; id < n_ids; ++id) {
                const int32_t i02 = *(const int32_t *) ((const char *) ids->data + iid1*ids->nb[1] + id*ids->nb[0]);
                CHIP_MMID_MATRIX_ROW(i02, matrix_row_counts[i02]) = (struct mmid_row_mapping) {id, iid1};
                matrix_row_counts[i02] += 1;
            }
        }
        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            const int64_t cne1 = matrix_row_counts[cur_a];
            if (cne1 > 0) {
                atomic_fetch_add_explicit(&ggml_chip_flops_total, cne1 * ne01 * ne10 * 2, memory_order_relaxed);
                atomic_fetch_add_explicit(&ggml_chip_bytes_total, cne1 * nb02, memory_order_relaxed);
            }
        }
        const int nth = ggml_chip_nthreads;
        int64_t total_chunks = 0;
        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            const int64_t cne1 = matrix_row_counts[cur_a];
            if (cne1 <= 0) {
                continue;
            }
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
            total_chunks += nchunk0 * nchunk1;
        }
        atomic_store_explicit(&ggml_chip_chunks_left, total_chunks, memory_order_relaxed);
    }

    {
        void * wd = ggml_chip_wdata;
        if (src1->type != GGML_TYPE_Q8_K) {
            incr_ptr_aligned(&wd, ggml_row_size(GGML_TYPE_Q8_K, ggml_nelements(src1)), sizeof(int64_t));
        }
        int64_t * matrix_row_counts = (int64_t *) incr_ptr_aligned(&wd, n_as*sizeof(int64_t), sizeof(int64_t));

        const size_t exp_bytes = (size_t) ne01 * nb01;
        int64_t n_sel = 0;
        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            if (matrix_row_counts[cur_a] > 0) {
                n_sel++;
            }
        }
        if (ggml_chip_sram_off_cap < n_as) {
            ggml_chip_sram_off = realloc(ggml_chip_sram_off, n_as * sizeof(int64_t));
            ggml_chip_sram_off_cap = n_as;
        }
        const size_t need = (size_t) n_sel * exp_bytes;
        if (ggml_chip_zcopy) {
            if ((size_t) ggml_chip_sram_cap < need) {
                ggml_chip_sram_cap = need;
            }
        } else if (ggml_chip_sram_cap < need) {
            ggml_chip_sram = ggml_chip_sram_aligned_realloc(ggml_chip_sram, ggml_chip_sram_cap, need);
            ggml_chip_sram_cap = need;
        }
        size_t pos = 0;
        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            if (matrix_row_counts[cur_a] > 0) {
                ggml_chip_sram_off[cur_a] = pos;
                pos += exp_bytes;
            } else {
                ggml_chip_sram_off[cur_a] = -1;
            }
        }
        atomic_store_explicit(&ggml_chip_copy_left, ggml_chip_nthreads, memory_order_relaxed);
        atomic_store_explicit(&ggml_chip_copy_done, 0, memory_order_relaxed);
        atomic_store_explicit(&ggml_chip_copy_started, 0, memory_order_relaxed);
        atomic_store_explicit(&ggml_chip_copy_next, 0, memory_order_relaxed);
        atomic_store_explicit(&ggml_chip_comp_started, 0, memory_order_relaxed);
        if (ggml_chip_expert_ready_cap < (size_t) n_as) {
            ggml_chip_expert_ready = realloc(ggml_chip_expert_ready, n_as * sizeof(_Atomic int));
            ggml_chip_expert_ready_cap = n_as;
        }
        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            atomic_store_explicit(&ggml_chip_expert_ready[cur_a], 0, memory_order_relaxed);
        }
    }

    atomic_store_explicit(&ggml_chip_pending, ggml_chip_nthreads, memory_order_release);
    atomic_fetch_add_explicit(&ggml_chip_ops_total, 1, memory_order_relaxed);
    for (int i = 0; i < ggml_chip_nthreads; i++) {
        sem_post(&ggml_chip_sem_submit[i]);
    }
}

static void ggml_chip_wait_done(void) {
    struct timespec ts;
    pthread_mutex_lock(&ggml_chip_done_mtx);
    while (atomic_load_explicit(&ggml_chip_pending, memory_order_acquire) != 0) {
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 3;
        pthread_cond_timedwait(&ggml_chip_done_cv, &ggml_chip_done_mtx, &ts);
    }
    pthread_mutex_unlock(&ggml_chip_done_mtx);
}

int chip_mul_mat_id(struct ggml_tensor * dst) {
    const struct ggml_tensor * src0 = dst->src[0];
    const struct ggml_tensor * src1 = dst->src[1];
    const struct ggml_tensor * ids  = dst->src[2];

    if (!chip_from_float) {
        return -1;
    }
    chip_vec_dot_fn vd = chip_vec_dot_for(src0->type);
    if (!vd) {
        CHIP_LOG("mmid reject: src0.type=%d src1.type=%d ids.type=%d ne=[%lld,%lld,%lld]\n",
            (int)src0->type, (int)src1->type, (int)ids->type,
            (long long)src0->ne[0], (long long)src0->ne[1], (long long)src0->ne[2]);
        return -2;
    }
    if (src1->type != GGML_TYPE_F32 && src1->type != GGML_TYPE_Q8_K) {
        return -3;
    }
    if (!ggml_is_contiguous(src0)) {
        return -4;
    }

    chip_vec_dot_cur = vd; /* workers read this after submit */
    ggml_chip_submit(dst);
    ggml_chip_wait_done();
    return 0;
}

int chip_core_init(chip_vec_dot_fn vd_q3_K, chip_vec_dot_fn vd_iq3_xxs,
                   chip_vec_dot_fn vd_iq3_s, chip_vec_dot_fn vd_iq4_xs,
                   void * from_float_q8_K) {
    (void)chip_nchips();
    (void)chip_nworkers();
    (void)chip_nt_copy();

    chip_vec_dot_tab[0] = vd_q3_K;
    chip_vec_dot_tab[1] = vd_iq3_xxs;
    chip_vec_dot_tab[2] = vd_iq3_s;
    chip_vec_dot_tab[3] = vd_iq4_xs;
    chip_from_float = (chip_from_float_fn) from_float_q8_K;
    if (!chip_vec_dot_tab[0] || !chip_from_float) {
        CHIP_LOG("FATAL: vec_dot/from_float missing\n");
        return -1;
    }

    ggml_chip_nt_copy = chip_nt_copy();
    ggml_chip_nthreads = chip_nworkers();
    {
        const char * zc = getenv("CHIP_ZCOPY");
        if (zc && strcmp(zc, "0") == 0) {
            ggml_chip_zcopy = 0;
        }
    }
    pthread_mutex_init(&ggml_chip_done_mtx, NULL);
    pthread_cond_init(&ggml_chip_done_cv, NULL);
    atomic_store_explicit(&ggml_chip_sync_mode, 0, memory_order_relaxed);
    atomic_store_explicit(&ggml_chip_copy_only, 0, memory_order_relaxed);
    atomic_store_explicit(&ggml_chip_pending, 0, memory_order_relaxed);

    for (int i = 0; i < CHIP_MAX_THREADS; i++) {
        sem_init(&ggml_chip_sem_submit[i], 0, 0);
    }
    for (int i = 0; i < ggml_chip_nthreads; i++) {
        pthread_create(&ggml_chip_threads[i], NULL, ggml_chip_thread_main, (void *)(intptr_t)i);
    }

    CHIP_LOG("init: nchips=%d workers=%d nt_copy=%d zcopy=%d\n", chip_nchips(), ggml_chip_nthreads, ggml_chip_nt_copy, ggml_chip_zcopy);
    return 0;
}

void chip_core_shutdown(void) {
    CHIP_LOG("ops=%lld copy=%.1fus comp=%.1fus bytes=%lldMB\n",
        (long long)atomic_load_explicit(&ggml_chip_ops_total, memory_order_relaxed),
        atomic_load_explicit(&ggml_chip_copy_ns_total, memory_order_relaxed) / 1000.0,
        atomic_load_explicit(&ggml_chip_compute_ns_total, memory_order_relaxed) / 1000.0,
        (long long)(atomic_load_explicit(&ggml_chip_copy_bytes_total, memory_order_relaxed) >> 20));
}

__attribute__((visibility("default")))
void ggml_backend_chip_get_stats(long long * flops, long long * bytes, long long * ops,
                                 long long * sram_bytes, int * workers) {
    if (flops) {
        *flops = (long long) atomic_load_explicit(&ggml_chip_flops_total, memory_order_relaxed);
    }
    if (bytes) {
        *bytes = (long long) atomic_load_explicit(&ggml_chip_bytes_total, memory_order_relaxed);
    }
    if (ops) {
        *ops = (long long) atomic_load_explicit(&ggml_chip_ops_total, memory_order_relaxed);
    }
    if (sram_bytes) {
        *sram_bytes = (long long) ggml_chip_sram_cap;
    }
    if (workers) {
        *workers = ggml_chip_nthreads;
    }
}
