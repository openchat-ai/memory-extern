#!/bin/bash
cd /mnt/f/sram/sram/pim/research-cli
gcc -O2 -o /tmp/bwtest bwtest.c -pthread || exit 1
for mb in 64 256 1024; do
  /tmp/bwtest 1 "$mb" 10
done
echo "--- parallel 64MB/thread ---"
for n in 2 4 8 16 32; do
  /tmp/bwtest "$n" 64 10
done