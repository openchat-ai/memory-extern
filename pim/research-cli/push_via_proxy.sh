#!/bin/bash
cd /mnt/f/sram/sram || exit 1
git remote get-url origin >/dev/null 2>&1 || \
  git remote add origin https://gh-proxy.com/https://github.com/openchat-ai/memory-extern.git
pgrep -f connect_proxy.py >/dev/null || nohup python3 /mnt/f/sram/sram/pim/research-cli/connect_proxy.py >/tmp/connect_proxy.log 2>&1 &
sleep 1
for i in 1 2 3; do
  echo "---try $i---"
  if git -c http.version=HTTP/1.1 push origin main 2>&1; then
    echo "PUSH_OK"
    exit 0
  fi
  sleep 3
done
echo "PUSH_FAIL"
exit 1