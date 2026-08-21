#!/bin/bash
BIN=/root/sparkmoe-fork/build/bin/research-cli
MODEL=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
timeout 240 $BIN -m $MODEL -ngl 0 -t 16 --chip-tok 0 --mlock --chip-offload 8 --temp 0 --seed 42 -n 60 -p "用一句话介绍你自己。" --log-disable 2>&1 > /tmp/off8.log
echo "=== generation text (tok lines with piece) ==="
grep -E 'tok\[[0-9]+\] = [0-9]+ piece' /tmp/off8.log | awk -F'piece=' '{printf "%s", $2}' | tr -d '\n'
echo ""
echo "=== [gen] summary ==="
grep -E '\[gen\]' /tmp/off8.log