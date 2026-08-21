import shutil

p = "/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c"
shutil.copy(p, p + ".bak3")

with open(p) as f:
    c = f.read()

old_reset = """    for (int cur_a = ith; cur_a < n_as; cur_a += nth) {
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
        const int64_t cne1 = matrix_row_counts[cur_a];"""

new_reset = """    for (int cur_a = 0; cur_a < n_as; ++cur_a) {
        const int64_t cne1 = matrix_row_counts[cur_a];"""

assert old_reset in c, "run_op reset block not found"
c = c.replace(old_reset, new_reset, 1)

old_submit = """    atomic_store_explicit(&ggml_chip_pending, ggml_chip_nthreads, memory_order_release);"""
new_submit = """    {
        void * wd = params->wdata;
        if (src1->type != vec_dot_type) {
            incr_ptr_aligned(&wd, ggml_row_size(vec_dot_type, ggml_nelements(src1)), sizeof(int64_t));
        }
        int64_t * matrix_row_counts = (int64_t *) incr_ptr_aligned(&wd, n_as*sizeof(int64_t), sizeof(int64_t));
        struct mmid_row_mapping * matrix_rows = (struct mmid_row_mapping *) incr_ptr_aligned(&wd, n_as*n_ids*ids->ne[1]*sizeof(struct mmid_row_mapping), sizeof(int64_t));
        char (*atomic_current_chunk)[CACHE_LINE_SIZE] = (char (*)[CACHE_LINE_SIZE]) incr_ptr_aligned(&wd, CACHE_LINE_SIZE * n_as, CACHE_LINE_SIZE);

        for (int cur_a = 0; cur_a < n_as; ++cur_a) {
            atomic_int * current_chunk_ctr = (atomic_int *)(atomic_current_chunk + cur_a);
            *current_chunk_ctr = ggml_chip_nthreads;
        }
        memset(matrix_row_counts, 0, n_as*sizeof(int64_t));
        for (int64_t iid1 = 0; iid1 < ids->ne[1]; ++iid1) {
            for (int id = 0; id < n_ids; ++id) {
                const int32_t i02 = *(const int32_t *) ((const char *) ids->data + iid1*ids->nb[1] + id*ids->nb[0]);
                MMID_MATRIX_ROW(i02, matrix_row_counts[i02]) = (struct mmid_row_mapping) {id, iid1};
                matrix_row_counts[i02] += 1;
            }
        }
    }

    atomic_store_explicit(&ggml_chip_pending, ggml_chip_nthreads, memory_order_release);"""

assert old_submit in c, "submit anchor not found"
c = c.replace(old_submit, new_submit, 1)

with open(p, "w") as f:
    f.write(c)
print("patched: prep moved to submitter")
