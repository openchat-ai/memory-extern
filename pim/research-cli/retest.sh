#!/bin/bash
tmux send-keys -t chat '测试' Enter
sleep 40
grep -E '^\[gen\]|moe_stats' /root/live.log | tail -3
grep 'chip\]' /root/live.log | tail -2
