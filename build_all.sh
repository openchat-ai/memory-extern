#!/bin/bash
set -e
SRC=/data/data/com.termux/files/home/models/rStar-Coder-Qwen3-0.6B.Q8_0.gguf
MID=/data/data/com.termux/files/home/models/qxt/rStar-Coder-Qwen3-0.6B.Q8_0-Q1T_lloyd.gguf
OUT=/data/data/com.termux/files/home/models/qxt/coder-q1-e7m0-nl.gguf
rm -f "$MID" "$OUT"
python3 tools/qxt_build_model.py 1 "$SRC" --cb 0.34188 2>&1 | grep -vE "^  \[" 
taskset -c 4-8 llama-quantize --allow-requantize --leave-output-tensor --token-embedding-type q8_0 "$MID" "$OUT" Q1_0 4 2>&1 | grep -E "quant size|error|failed"
ls -la "$OUT"
