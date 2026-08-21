#!/bin/bash
PID=$(pgrep -x research-cli | head -1)
echo "PID=$PID"
if [ -n "$PID" ]; then
    grep -E 'VmRSS|Threads' /proc/$PID/status
    echo "=== stack (gdb) ==="
    timeout 20 gdb -p $PID -batch -ex 'thread apply all bt 3' 2>/dev/null | grep -E '^Thread|sem_wait|pthread_cond|ggml_chip|llama' | head -30
fi
