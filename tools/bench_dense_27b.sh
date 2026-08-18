#!/usr/bin/env bash
# bench_dense_27b.sh — 把 dense Qwen3.8-27B 在 CPU 上能榨到多快, 一脚本量出
#
# 三个旋钮, 每个都独立测一遍:
#   [1] 基线        : llama-bench 单流生成 (纯 read-all-weights, Q3)
#   [2] 投机解码    : llama-cli --spec-type draft-mtp (Qwen3.8-27B 自带 MTP 头,
#                                              无需额外 draft 模型) → 有效 t/s
#   [3] 并发批处理  : llama-batched-bench npl=1,2,4,8 → 共享权重的聚合吞吐
#
# 注意 (2026 年 llama.cpp 命名):
#   - llama-bench 不支持投机解码参数 (只能 llama-cli/server 测).
#   - 投机解码 flag 已在 2026-04 重构: --spec-draft-n-max; 2026-05 又把
#     --spec-type mtp 改名为 --spec-type draft-mtp. 脚本两者都试, 失败不报错.
#
# 用法:
#   bash tools/bench_dense_27b.sh                                  # 自动找 27B
#   MODEL_27B=/path/to/qwen3.8-27b-q3_K_M.gguf bash tools/bench_dense_27b.sh
#   bash tools/bench_dense_27b.sh --nospec   # 跳过投机解码 (旧 build 报错时用)
#
# 环境变量:
#   MODELS_DIR  模型查找目录 (默认 <repo>/models, 其次 ~/models)
#   MODEL_27B   显式指定 27B 文件
#   CTX         上下文 (默认 8192)

set -uo pipefail

CTX="${CTX:-8192}"
SWD="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${MODELS_DIR:-$SWD/models}"

SKIP_SPEC=0
for a in "$@"; do
  [ "$a" = "--nospec" ] && SKIP_SPEC=1
done

find_local() {
  find "$1" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null \
    | grep -i "$2" | head -1 || true
}

MODEL_27B="${MODEL_27B:-}"
if [ -z "$MODEL_27B" ]; then
  MODEL_27B="$(find_local "$MODELS_DIR" "27b")"
  [ -z "$MODEL_27B" ] && MODEL_27B="$(find_local "$HOME/models" "27b")"
fi

bench_tg() {  # bench_tg <model> → 打印 tg t/s
  local out
  out="$( { llama-bench -m "$1" -p 64 -n 128 -c "$CTX" -ngl 0 2>/dev/null || true; } \
          | grep -iE '^\|\s*tg' || true )"
  echo "$out" | grep -oE '[0-9.]+' | head -1 || true
}

cli_tts() {  # cli_tts <args...> → llama-cli 生成的 t/s (解析 tokens per second / eval)
  local out toks=0 ms=0 tps=""
  out="$( { llama-cli -ngl 0 -c "$CTX" -s 42 --temp 0.0 -no-cnv --no-display-prompt \
             "$@" 2>/dev/null || true; } )"
  tps="$(echo "$out" | grep -oE '[0-9.]+ tokens per second' | tail -1 | grep -oE '^[0-9.]+' || true)"
  if [ -z "$tps" ]; then
    toks="$(echo "$out" | grep -oE 'eval +n *= *[0-9]+' | tail -1 | grep -oE '[0-9]+' || true)"
    ms="$(echo "$out" | grep -oE 'eval +time *= *[0-9.]+' | tail -1 | grep -oE '[0-9.]+' || true)"
    if [ -n "${toks:-}" ] && [ -n "${ms:-}" ] && [ "$(echo "$ms > 0" | bc 2>/dev/null || echo 1)" = "1" ]; then
      tps="$(echo "scale=2; $toks / ($ms / 1000)" | bc)"
    fi
  fi
  printf '%s' "$tps"
}

echo "=== [0/5] 环境检查 ==="
command -v llama-cli        >/dev/null && echo "  llama-cli:        OK" || echo "  llama-cli:        MISSING"
command -v llama-bench      >/dev/null && echo "  llama-bench:      OK" || echo "  llama-bench:      MISSING"
command -v llama-batched-bench >/dev/null && echo "  llama-batched-bench: OK" || echo "  llama-batched-bench: MISSING (可只用滑块 1/2)"
command -v llama-cli >/dev/null || { echo "  需要 llama.cpp (含 llama-cli), 请先安装再跑."; exit 1; }

echo
echo "=== [1/5] 定位 dense 27B ==="
if [ -n "$MODEL_27B" ] && [ -f "$MODEL_27B" ]; then
  echo "  $MODEL_27B"
else
  echo "  未找到 *27b*.gguf; 用 MODEL_27B=<路径> 指定."; exit 2
fi

echo
echo "=== [2/5] 滑块1: 单流基线 (llama-bench, tg) ==="
T_BASE="$(bench_tg "$MODEL_27B")"
echo "  基线 ≈ ${T_BASE:-N/A} t/s   ← dense 读全量权重的天花板"

echo
echo "=== [3/5] 滑块2: MTP 投机解码 (llama-cli, draft-mtp) ==="
T_MTP=""
if [ $SKIP_SPEC -eq 0 ]; then
  PROMPT="def fibonacci(n):\n    if n <= 1:\n        return n\n    return fibonacci(n-1) + fibonacci(n-2)"
  if T="$(cli_tts -m "$MODEL_27B" --spec-type draft-mtp --spec-draft-n-max 2 \
                      -p "$PROMPT" -n 96)"; then
    if [ -n "$T" ]; then T_MTP="$T"; else
      T="$(cli_tts -m "$MODEL_27B" --spec-type mtp --spec-draft-n-max 2 -p "$PROMPT" -n 96)" && T_MTP="$T"
    fi
  fi
  echo "  MTP 投机 ≈ ${T_MTP:-N/A} t/s   (build 不支持时为空, 可 --nospec 跳过)"
else
  echo "  已跳过 (--nospec)"
fi

echo
echo "=== [4/5] 滑块3: 并发批处理 (llama-batched-bench, npl=1,2,4,8) ==="
if command -v llama-batched-bench >/dev/null; then
  echo "  权重一次读入, 多请求共享 → 聚合 t/s 随 npl 摊薄带宽:"
  llama-batched-bench -m "$MODEL_27B" -c 8192 -b 2048 -ub 512 \
    -npp 128 -pps -ntg 128 -npl 1,2,4,8 -ngl 0 2>/dev/null | grep -E '^\| *[0-9]' || true
else
  echo "  无 llama-batched-bench, 跳过本例."
fi

echo
echo "=== [5/5] 汇总 ==="
echo "  单流基线  : ${T_BASE:-N/A} t/s"
echo "  MTP 投机   : ${T_MTP:-N/A} t/s"
echo "  你要的 '写代码跟手' 取决于这张表: 交互单流看 [1][2], 并发/脚本流看 [3]."
echo
echo "  判断标准:"
echo "    * 单流 (~4 t/s) 变不了 50 → dense 物理墙, 这不为谁代码可狡辩. "
echo "    * MTP 投机若 >1.5x 基线, 说明你的日常档位直接用 --spec-type draft-mtp."
echo "    * batched-bench 的 S t/s 列若随 npl 显著上扬 → '自动/并发补全' 是你把"
echo "      27B 用爽的正路; 单流热闹是假热闹."