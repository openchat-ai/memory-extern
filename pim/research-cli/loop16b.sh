#!/bin/bash
for i in $(seq 1 60); do
  /root/chip_test 16 >/tmp/out16.log 2>/tmp/w16.log
  if grep -q 'zeros=[1-9]' /tmp/out16.log; then
    echo "=== FAILED iter $i ==="
    head -1 /tmp/out16.log
    echo "--- submits ---"
    grep -c '\[chip-dbg\] submit' /tmp/w16.log
    echo "--- [c] lines per submit (exp=0) ---"
    awk '/\[chip-dbg\] submit/{n++} /\[c\] ith=.* exp=0 /{c[n]++} END{for(i=1;i<=n;i++) print "submit",i,"exp0_chunks=",c[i]}' /tmp/w16.log
    echo "--- last submit's chunk coverage ---"
    awk 'BEGIN{last=0} /\[chip-dbg\] submit/{last=NR} /\[c\]/{if(NR>last) print}' /tmp/w16.log | grep 'exp=0' | awk '{print $2}' | sort -t= -k2 -n | head -20
    exit 0
  fi
done
echo "all 60 passed"