#!/bin/bash
cd /mnt/f/sram/sram || exit 1
git remote get-url origin >/dev/null 2>&1 || \
  git remote add origin https://gh-proxy.com/https://github.com/openchat-ai/memory-extern.git
for i in 1 2 3 4; do
  echo "---try $i---"
  if git -c http.version=HTTP/1.1 -c http.lowSpeedLimit=1 -c http.lowSpeedTime=600 push origin main 2>&1; then
    echo "PUSH_OK"
    exit 0
  fi
  sleep 5
done
echo "PUSH_FAIL"
exit 1