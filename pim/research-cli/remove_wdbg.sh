#!/bin/bash
set -e
F=/root/sparkmoe-fork/ggml/src/ggml-cpu/ggml-cpu.c
cp $F.bak6 $F
grep -n '\[w\] ith=' $F || echo "clean (no wdbg lines)"