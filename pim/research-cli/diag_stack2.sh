#!/bin/bash
PID=$(pgrep -x research-cli | head -1)
timeout 25 gdb -p $PID -batch -ex 'thread apply all bt 8' 2>/dev/null > /tmp/stack.txt
echo "=== thread 1 (main) ==="
awk '/^Thread 1 /{f=1} f&&/^Thread 2 /{exit} f' /tmp/stack.txt | head -12
echo "=== thread 2 ==="
awk '/^Thread 2 /{f=1} f&&/^Thread 3 /{exit} f' /tmp/stack.txt | head -10
