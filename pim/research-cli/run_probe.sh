#!/bin/bash
cd /root
printf '你好，用一句话介绍自己。\n' | exec /root/sparkmoe-fork/build/bin/research-cli -m /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf -ngl 0 -t 16 -i --chip-tok 33.9 --temp 0 --seed 42 -n 12 > /root/chip_probe.log 2>&1