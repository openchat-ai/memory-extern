#!/bin/bash
set -e
gcc /mnt/f/sram/sram/pim/research-cli/bench_chip.c -o /root/bench_chip \
    -I/root/sparkmoe-fork/ggml/include \
    -O2 -D_XOPEN_SOURCE=600 -lm -lpthread \
    -L/root/sparkmoe-fork/build/bin -lggml -lggml-base -lggml-cpu \
    -Wl,-rpath,/root/sparkmoe-fork/build/bin
echo "=== built, running ==="
/root/bench_chip 4 200