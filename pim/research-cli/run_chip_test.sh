#!/bin/bash
set -e
gcc /mnt/f/sram/sram/pim/research-cli/chip_test.c -o /root/chip_test \
    -I/root/sparkmoe-fork/ggml/include \
    -O2 -lm -lpthread \
    -L/root/sparkmoe-fork/build/bin -lggml -lggml-base -lggml-cpu \
    -Wl,-rpath,/root/sparkmoe-fork/build/bin
echo "=== built, running ==="
/root/chip_test 2; /root/chip_test 4
