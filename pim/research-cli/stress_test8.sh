#!/bin/bash
for n in 8 16; do
  pass=0; fail=0
  for i in $(seq 1 20); do
    if /root/chip_test $n 2>/dev/null | grep -qE 'zeros=[1-9]'; then
      fail=$((fail+1)); echo "FAIL nchip=$n iter=$i"; /root/chip_test $n 2>/dev/null | head -2
    else
      pass=$((pass+1))
    fi
  done
  echo "nchip=$n: pass=$pass fail=$fail"
done