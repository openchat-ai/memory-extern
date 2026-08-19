#!/bin/bash
LOG=/mnt/f/sram/sram/data/reinject/retarget_v2.log
start=$(date +%s)
/root/llama_retarget /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-v2.gguf --from iq3_xxs,iq3_s,iq4_xs --to q8_0 -t 8 > "$LOG" 2>&1
rc=$?
end=$(date +%s)
echo "RETARGET_DONE rc=$rc elapsed=$((end-start))s" >> "$LOG"
echo "DONE rc=$rc elapsed=$((end-start))s"