#!/bin/bash
cd /mnt/f/sram/sram/pim/research-cli
gcc -O2 -o /tmp/bwtest2 bwtest2.c -pthread || exit 1
echo "=== single-thread small block ==="
for kb in 16 128 426; do
  /tmp/bwtest2 1 "$kb" 2000
done
echo "=== parallel 426KB ==="
for n in 2 4 8 16; do
  /tmp/bwtest2 "$n" 426 2000
done