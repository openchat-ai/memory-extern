#!/bin/bash
set -e
F=/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c
# remove ONLY the [c] debug line, keep per-worker semaphore fix intact
perl -0pi -e 's/            fprintf\(stderr, "\[c\] ith=%d nth=%d exp=%d r0=%lld r1=%lld ir0=%lld ir1=%lld\\n", ith, nth, cur_a, \(long long\) ir0_start, \(long long\) ir0_end, \(long long\) ir1_start, \(long long\) ir1_end\);\n//' $F
grep -c '\[c\] ith=' $F || echo "chunklog removed"
grep -n 'ggml_chip_sem_submit' $F