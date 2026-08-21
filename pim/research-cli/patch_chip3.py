import shutil

p = "/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c"
shutil.copy(p, p + ".bak4")

with open(p) as f:
    c = f.read()

old_state = """static sem_t ggml_chip_sem_submit;
static _Atomic int ggml_chip_pending;"""
new_state = """static sem_t ggml_chip_sem_submit;
static pthread_mutex_t ggml_chip_done_mtx;
static pthread_cond_t ggml_chip_done_cv;
static _Atomic int ggml_chip_pending;"""
assert old_state in c
c = c.replace(old_state, new_state, 1)

old_sub = """        ggml_chip_run_op(ith, ggml_chip_nthreads);
        atomic_fetch_sub_explicit(&ggml_chip_pending, 1, memory_order_release);"""
new_sub = """        ggml_chip_run_op(ith, ggml_chip_nthreads);
        pthread_mutex_lock(&ggml_chip_done_mtx);
        if (atomic_fetch_sub_explicit(&ggml_chip_pending, 1, memory_order_release) == 1) {
            pthread_cond_signal(&ggml_chip_done_cv);
        }
        pthread_mutex_unlock(&ggml_chip_done_mtx);"""
assert old_sub in c
c = c.replace(old_sub, new_sub, 1)

old_wait = """static void ggml_chip_wait_done(void) {
    while (atomic_load_explicit(&ggml_chip_pending, memory_order_acquire) != 0) {
        sched_yield();
    }
}"""
new_wait = """static void ggml_chip_wait_done(void) {
    pthread_mutex_lock(&ggml_chip_done_mtx);
    while (atomic_load_explicit(&ggml_chip_pending, memory_order_acquire) != 0) {
        pthread_cond_wait(&ggml_chip_done_cv, &ggml_chip_done_mtx);
    }
    pthread_mutex_unlock(&ggml_chip_done_mtx);
}"""
assert old_wait in c
c = c.replace(old_wait, new_wait, 1)

old_init = """        sem_init(&ggml_chip_sem_submit, 0, 0);
        atomic_init(&ggml_chip_pending, 0);"""
new_init = """        sem_init(&ggml_chip_sem_submit, 0, 0);
        pthread_mutex_init(&ggml_chip_done_mtx, NULL);
        pthread_cond_init(&ggml_chip_done_cv, NULL);
        atomic_init(&ggml_chip_pending, 0);"""
assert old_init in c
c = c.replace(old_init, new_init, 1)

with open(p, "w") as f:
    f.write(c)
print("patched: condvar sleep instead of spin")
