#!/bin/bash
set -e
F=/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c
perl -0pi -e 's/(const int64_t cne1 = matrix_row_counts\[cur_a\];\n)(\s*if \(cne1 == 0\))/$1        fprintf(stderr, "[w] ith=%d nth=%d exp=%lld cne1=%lld\\n", ith, nth, (long long) cur_a, (long long) cne1);\n$2/' $F
grep -n 'fprintf(stderr, "\[w\]' $F