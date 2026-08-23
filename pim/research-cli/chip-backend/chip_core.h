#ifndef CHIP_CORE_H
#define CHIP_CORE_H

#include <stddef.h>

struct ggml_tensor;

typedef void (*chip_vec_dot_fn)(int n, float * s, size_t bs, const void * vx, size_t bx, const void * vy, size_t by, int nrc);

int chip_core_init(chip_vec_dot_fn vec_dot_q3_K_q8_K, void * from_float_q8_K);
void chip_core_shutdown(void);
int chip_mul_mat_id(struct ggml_tensor * dst);

int chip_log_level(void);
int chip_nchips(void);
int chip_nworkers(void);
int chip_nt_copy(void);

#endif
