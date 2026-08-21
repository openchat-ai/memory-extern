#!/bin/bash
vmstat 1 3 | tail -3
echo ===kswapd===
grep -E 'pgscan_kswapd|pgsteal_kswapd' /proc/vmstat
echo ===proc===
ps -o pid,pcpu,rss,comm -p $(pidof research-cli)
echo ===meminfo===
grep -E 'MemAvailable|Cached|AnonPages|Mapped' /proc/meminfo
