#!/bin/bash
# 启动器：setsid 脱离会话后台跑 requant
set -e
setsid bash /mnt/f/sram/sram/tools/run_requant.sh > /root/requant_nohup.out 2>&1 < /dev/null &
echo "launcher pid=$!"
