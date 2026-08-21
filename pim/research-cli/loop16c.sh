#!/bin/bash
for i in $(seq 1 60); do
  /root/chip_test 16 >/tmp/out16.log 2>/tmp/w16.log
  if grep -q 'zeros=[1-9]' /tmp/out16.log; then
    echo "=== FAILED iter $i ==="
    head -1 /tmp/out16.log
    echo "--- full [c] log, first submit ---"
    awk '/\[chip-dbg\] submit/{s++} s==1 && /\[c\]/' /tmp/w16.log
    exit 0
  fi
done
echo "all 60 passed"