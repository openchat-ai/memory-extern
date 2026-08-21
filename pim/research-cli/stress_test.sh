#!/bin/bash
for n in 2 4; do
  for i in $(seq 1 30); do
    if /root/chip_test $n 2>/dev/null | grep -qE 'zeros=[1-9]'; then
      echo "FAIL nchip=$n iter=$i"
      exit 1
    fi
  done
  echo "nchip=$n: 30/30 pass"
done
echo ALL_PASS