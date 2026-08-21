#include <stdio.h>
#include <stdlib.h>
#include <omp.h>

int main(int argc, char ** argv) {
    const int threads = argc > 1 ? atoi(argv[1]) : 16;
    omp_set_num_threads(threads);
    const size_t n = 768UL * 1024 * 1024;
    float * a = aligned_alloc(64, n * sizeof(float));
    float * b = aligned_alloc(64, n * sizeof(float));
    float * c = aligned_alloc(64, n * sizeof(float));
    if (!a || !b || !c) { fprintf(stderr, "alloc failed\n"); return 1; }
    #pragma omp parallel for
    for (size_t i = 0; i < n; i++) { a[i] = 1.0f; b[i] = 2.0f; c[i] = 0.5f; }
    const double bytes_triad = (double) n * sizeof(float) * 3.0;
    const double bytes_read = (double) n * sizeof(float);
    double best_triad = 0.0, best_read = 0.0;
    for (int r = 0; r < 3; r++) {
        double t0 = now();
        #pragma omp parallel for
        for (size_t i = 0; i < n; i++) a[i] = b[i] + 3.0f * c[i];
        double t1 = now();
        double gbs = bytes_triad / (t1 - t0) / 1e9;
        if (gbs > best_triad) best_triad = gbs;
        double s = 0.0;
        t0 = now();
        #pragma omp parallel for reduction(+ : s)
        for (size_t i = 0; i < n; i++) s += b[i];
        t1 = now();
        gbs = bytes_read / (t1 - t0) / 1e9;
        if (gbs > best_read) best_read = gbs;
        if (s == 42.0f) printf(" ");
    }
    printf("threads=%d array=%.1fGB x3\n", threads, n * sizeof(float) / 1e9);
    printf("STREAM Triad : %.1f GB/s (%.1f GiB/s)\n", best_triad, best_triad / 1.073741824);
    printf("STREAM Read  : %.1f GB/s (%.1f GiB/s)\n", best_read, best_read / 1.073741824);
    free(a); free(b); free(c);
    return 0;
}