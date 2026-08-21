import shutil

p = "/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c"
shutil.copy(p, p + ".bak5")

with open(p) as f:
    c = f.read()

old_wait = """static void ggml_chip_wait_done(void) {
    pthread_mutex_lock(&ggml_chip_done_mtx);
    while (atomic_load_explicit(&ggml_chip_pending, memory_order_acquire) != 0) {
        pthread_cond_wait(&ggml_chip_done_cv, &ggml_chip_done_mtx);
    }
    pthread_mutex_unlock(&ggml_chip_done_mtx);
}"""
new_wait = """static void ggml_chip_wait_done(void) {
    struct timespec ts;
    pthread_mutex_lock(&ggml_chip_done_mtx);
    while (atomic_load_explicit(&ggml_chip_pending, memory_order_acquire) != 0) {
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += 3;
        if (pthread_cond_timedwait(&ggml_chip_done_cv, &ggml_chip_done_mtx, &ts) == ETIMEDOUT) {
            fprintf(stderr, "[chip-dbg] TIMEOUT pending=%d ops=%lld nthreads=%d\\n",
                atomic_load_explicit(&ggml_chip_pending, memory_order_relaxed),
                (long long) atomic_load_explicit(&ggml_chip_ops_total, memory_order_relaxed),
                ggml_chip_nthreads);
        }
    }
    pthread_mutex_unlock(&ggml_chip_done_mtx);
}"""
assert old_wait in c
c = c.replace(old_wait, new_wait, 1)

old_sub = """    atomic_store_explicit(&ggml_chip_pending, ggml_chip_nthreads, memory_order_release);"""
new_sub = """    fprintf(stderr, "[chip-dbg] submit n_as=%d n_ids=%d\\n", n_as, n_ids);
    atomic_store_explicit(&ggml_chip_pending, ggml_chip_nthreads, memory_order_release);"""
assert old_sub in c
c = c.replace(old_sub, new_sub, 1)

old_run = """        ggml_chip_run_op(ith, ggml_chip_nthreads);
        pthread_mutex_lock(&ggml_chip_done_mtx);"""
new_run = """        ggml_chip_run_op(ith, ggml_chip_nthreads);
        if (ith == 0) {
            fprintf(stderr, "[chip-dbg] worker0 done\\n");
        }
        pthread_mutex_lock(&ggml_chip_done_mtx);"""
assert old_run in c
c = c.replace(old_run, new_run, 1)

with open(p, "w") as f:
    f.write(c)
print("patched: debug timeouts")
