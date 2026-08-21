#!/bin/bash
cp /mnt/f/sram/sram/pim/research-cli/ggml-cpu.c /root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c
cd /root/sparkmoe-fork/build && make ggml-cpu 2>&1 | tail -2
cd /mnt/f/sram/sram/pim/research-cli
gcc -O2 -o bench_chip bench_chip.c -I/root/sparkmoe-fork/ggml/include -I/root/sparkmoe-fork/ggml/src -L/root/sparkmoe-fork/build/bin -Wl,-rpath,/root/sparkmoe-fork/build/bin -lggml-cpu -lggml-base -lggml -lm -pthread
./bench_chip 2>&1 | grep -vE "chip-dbg"