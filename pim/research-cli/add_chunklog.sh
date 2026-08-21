#!/bin/bash
set -e
F=/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c
cp $F.bak6 $F

# add chunk-level log in chip run_op, right before one_chunk call
perl -0pi -e 's/(\s+)ggml_compute_forward_mul_mat_id_one_chunk\(\n\s+\(struct ggml_tensor \*\) dst, src0, src1, ids, cur_a,/$1fprintf(stderr, "[c] ith=%d nth=%d exp=%d r0=%lld r1=%lld ir0=%lld ir1=%lld\\n", ith, nth, cur_a, (long long) ir0_start, (long long) ir0_end, (long long) ir1_start, (long long) ir1_end);$1ggml_compute_forward_mul_mat_id_one_chunk(\n$1    (struct ggml_tensor *) dst, src0, src1, ids, cur_a,/' $F

grep -n '\[c\] ith=' $F