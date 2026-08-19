#!/bin/bash
# 加载测试 + 小生成对比。跑原模型 Q3 与注入版 8bit，各 16 token。
set -e
export OMP_NUM_THREADS=8
CLI=/root/sparkmoe-fork/build/bin/research-cli
Q3=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
B8=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf
PROMPT="The quick brown fox jumps over the lazy dog. Write a short sentence about what happens next:"
OUT=/mnt/f/sram/sram/data/pim/inject_compare
mkdir -p "$OUT"
echo "[$(date +%T)] Q3 run start"
timeout 1800 "$CLI" -m "$Q3" -p "$PROMPT" -n 16 -t 8 -c 4096 2>&1 | tee "$OUT/q3.log" || echo "Q3 exit=$?"
echo "[$(date +%T)] Q3 done, now 8bit run"
timeout 1800 "$CLI" -m "$B8" -p "$PROMPT" -n 16 -t 8 -c 4096 2>&1 | tee "$OUT/b8.log" || echo "B8 exit=$?"
echo "[$(date +%T)] all done"