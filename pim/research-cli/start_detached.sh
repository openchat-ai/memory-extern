#!/bin/bash
BIN=/root/sparkmoe-fork/build/bin/research-cli
setsid $BIN -m /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf -ngl 0 -t 16 -i --chip-tok 33.9 --mlock --chip-offload 8 --temp 0 --seed 42 -n 200 2>&1 | tee /root/live.log > /dev/null &
echo "started PID=$!"
sleep 30
ps aux | grep research-cli | grep -v grep | head -2
echo "=== log tail ==="
tail -3 /root/live.log