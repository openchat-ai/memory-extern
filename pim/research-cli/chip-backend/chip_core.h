#ifndef CHIP_CORE_H
#define CHIP_CORE_H

#include <stddef.h>

struct ggml_tensor;

typedef void (*chip_vec_dot_fn)(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc);

int chip_core_init(chip_vec_dot_fn vec_dot_q3_K_q8_K,
                   chip_vec_dot_fn vec_dot_iq3_xxs_q8_K,
                   chip_vec_dot_fn vec_dot_iq3_s_q8_K,
                   chip_vec_dot_fn vec_dot_iq4_xs_q8_K,
                   void * from_float_q8_K);
void chip_core_shutdown(void);
void ggml_backend_chip_get_stats(long long * flops, long long * bytes, long long * ops,
                                 long long * sram_bytes, int * workers);
int chip_mul_mat_id(struct ggml_tensor * dst);

int chip_log_level(void);
int chip_nchips(void);
int chip_nworkers(void);
int chip_nt_copy(void);

#endif
