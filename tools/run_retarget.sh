#!/bin/bash
# 注入 8bit 表示：iq3_xxs/iq3_s/iq4_xs -> Q8_0，其余原样。用 llama.cpp 官方 API。
set -e
IN=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
OUT=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-llama.gguf
LOG=/mnt/f/sram/sram/data/pim/retarget.log
echo "[$(date +%T)] start retarget -> $OUT"
/root/llama_retarget "$IN" "$OUT" --from iq3_xxs,iq3_s,iq4_xs --to q8_0 -t 8 > "$LOG" 2>&1
rc=$?
echo "[$(date +%T)] done, exit=$rc"
ls -la "$OUT"
exit $rc