#!/bin/bash
BIN=/root/sparkmoe-fork/build/bin/research-cli
MODEL=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
echo "=== offload 8, show_ids, 60 tok ==="
timeout 240 $BIN -m $MODEL -ngl 0 -t 16 --chip-tok 0 --mlock --chip-offload 8 --temp 0 --seed 42 -n 60 -p "用一句话介绍你自己。" --log-disable 2>&1 | grep -vE 'chip-dbg|^\[chip\]|~llama|^ggml|CPU compute buffer' | head -40