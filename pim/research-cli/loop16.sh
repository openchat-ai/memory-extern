#!/bin/bash
for i in $(seq 1 40); do
  /root/chip_test 16 >/tmp/out16.log 2>/tmp/w16.log
  if grep -q 'zeros=[1-9]' /tmp/out16.log; then
    echo "=== FAILED iter $i ==="
    head -2 /tmp/out16.log
    echo "=== which workers never wrote (missing exp=0 r0 blocks) ==="
    grep '\[c\]' /tmp/w16.log | grep -E 'exp=0 ' | awk '{print $2, $5}' | sort | uniq -c | head -40
    exit 0
  fi
done
echo "all 40 passed"