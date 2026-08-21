#!/bin/bash
ps aux | grep '[r]esearch-cli' | head -2
echo ===
cat /proc/$(pidof research-cli)/cmdline | tr '\0' ' '
echo
echo ===direct test===
/root/sparkmoe-fork/build/bin/research-cli --chip-offload 4 --chip-tok 33.9 -m /root/models/Qwen3.6-35B-A3B-UD-Q3_K_S.gguf -ngl 0 -t 2 -p hi -n 1 --temp 0 2>&1 | grep -E 'offload|error' | head -3
