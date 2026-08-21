#!/bin/bash
BIN=/root/sparkmoe-fork/build/bin/research-cli
MODEL=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
echo "=== running non-interactive with offload 8 ==="
timeout 180 $BIN -m $MODEL -ngl 0 -t 16 --chip-tok 33.9 --mlock --chip-offload 8 --temp 0 --seed 42 -n 40 -p "用一句话介绍你自己。" 2>&1 | grep -vE 'chip-dbg' | tail -25