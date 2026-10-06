#!/usr/bin/env bash
# run_llama_pinned.sh - 骁龙 8 Gen 1 (taro) decode 加速封装
#
# 实测结论 (results/speed_topology.md, 2026-10-06):
#   全 8 核 (默认)        : ~3.15 t/s
#   绑 cpu4-7 + 4 线程    : ~28.68 t/s   (×9)
# 小核 A510 参与 decode 是负资产, 崩速度。
#
# 用法:
#   ./run_llama_pinned.sh llama-bench [llama-bench 参数...]
#   ./run_llama_pinned.sh llama-cli   [llama-cli 参数...]
set -euo pipefail

# 大核组: cpu4-6 (A710) + cpu7 (X2) = 4 核
PINSET="4-7"
THREADS=4

BIN="$1"; shift

echo "[pin] $BIN on cpuset=$PINSET, threads=$THREADS" >&2
exec taskset -c "$PINSET" "$BIN" "$@" -t "$THREADS"