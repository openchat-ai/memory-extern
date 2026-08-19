#!/bin/bash
# 注入 8bit 表示：iq3_xxs/iq3_s/iq4_xs -> Q8_0，其余原样。输出到 /root/models。
set -e
IN=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
OUT=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf
echo "[$(date +%T)] start requant -> $OUT"
/root/gguf_requant "$IN" "$OUT" 2>&1 | tee /mnt/f/sram/sram/data/pim/requant.log
echo "[$(date +%T)] done, exit=$?"
ls -la "$OUT"
