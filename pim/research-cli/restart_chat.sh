#!/bin/bash
tmux send-keys -t chat C-c
sleep 2
tmux send-keys -t chat "research-cli -m /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf -ngl 0 -t 16 -i --chip-tok 33.9 --mlock --chip-offload 8 --temp 0 --seed 42 -n 200 2>&1 | tee /root/live.log"
tmux send-keys -t chat Enter