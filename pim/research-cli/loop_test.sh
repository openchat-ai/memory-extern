#!/bin/bash
for i in $(seq 1 30); do
  /root/chip_test 2 >/tmp/out2.log 2>/tmp/w2.log
  if grep -q 'zeros=[1-9]' /tmp/out2.log; then
    echo "=== FAILED iteration $i ==="
    cat /tmp/out2.log | head -4
    echo "=== worker log (nth=2 sections) ==="
    grep '\[w\]' /tmp/w2.log | grep 'nth=2'
    exit 0
  fi
done
echo "all 30 passed"