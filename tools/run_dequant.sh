#!/bin/bash
# 编译 dequant_tensor 并从 GGUF 抽真实张量的行，确认各张量真实量化类型
set -e
FORK=/root/sparkmoe-fork
MODEL=/root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf
OUT=/mnt/f/sram/sram/data/pim
mkdir -p "$OUT"

gcc -O2 -std=gnu11 \
  -I "$FORK/ggml/include" -I "$FORK/ggml/src" \
  /mnt/f/sram/sram/tools/dequant_tensor.c \
  -L "$FORK/build/bin" -lggml-cpu -lggml-base -lggml -lm \
  -o /root/dequant_tensor -Wl,-rpath,"$FORK/build/bin" || exit 1
echo "build ok"

for spec in "blk.0.ffn_gate_exps.weight:$OUT/blk0_gate_exps.f32" \
            "blk.0.ffn_down_exps.weight:$OUT/blk0_down_exps.f32" \
            "blk.0.ssm_out.weight:$OUT/blk0_ssm_out.f32"; do
  T=${spec%%:*}; F=${spec#*:}
  echo "==== $T ===="
  /root/dequant_tensor "$MODEL" "$T" 64 "$F" 2>&1 | grep -E 'tensor=|row 63'
done
