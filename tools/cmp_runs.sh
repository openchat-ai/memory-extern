#!/bin/bash
cmp -l /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-v2.gguf | head -20 > /mnt/f/sram/sram/data/reinject/cmp_head.txt
cmp -l /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit.gguf /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S-8bit-v2.gguf | wc -l > /mnt/f/sram/sram/data/reinject/cmp_count.txt
echo done