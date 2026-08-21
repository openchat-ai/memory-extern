#!/bin/bash
rm -f /tmp/tmux-0/default
tmux kill-server 2>/dev/null
sleep 1
tmux new-session -d -s chat "research-cli -m /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf -ngl 0 -t 16 -i --chip-tok 33.9 --mlock --chip-offload 8 --temp 0 --seed 42 -n 200 2>&1 | tee /root/live.log"
echo "started, waiting..."
sleep 25
tmux capture-pane -t chat -p 2>&1 | tail -10