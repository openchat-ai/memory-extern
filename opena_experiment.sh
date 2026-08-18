#!/usr/bin/env bash
# opena_experiment.sh — 开放项 A:一键合体 SparkMoE → 编译 → 采集 Qwen3.6 trace
#
# 跑法(WSL 或 Linux):
#   bash opena_experiment.sh                      # 全流程(会 clone llama.cpp + 编译, 耗时较长)
#   bash opena_experiment.sh --skip-build         # 已编译好则跳过 cmake(仍需模型路径)
#   MODEL=<gguf路径> bash opena_experiment.sh     # 显式指定模型(必填或交互)
#
# 环境假设:
#   * WSL/Ubuntu 已装 git cmake build-essential
#   * 模型文件 Qwen3.6-35B-A3B Q3 已在某路径
#
# 本脚本自动处理"合体/冲突":每次拷贝前先 diff 出差异量,
# 若差异巨大给出提示并停(避免盲覆盖);否则直接合入。
set -uo pipefail

REPO_SPARK="${REPO_SPARK:-$(cd "$(dirname "$0")/.." && pwd)/sparkmoe-src}"
WORK="${WORK:-$HOME/opena}"
MODEL="${MODEL:-}"
SKIP_BUILD=0
for a in "$@"; do [ "$a" = "--skip-build" ] && SKIP_BUILD=1; done

echo "===开放项A 一键合体==="
echo "Spark 零件: $REPO_SPARK"
echo "工作目录 : $WORK"

if [ -z "$MODEL" ]; then
  echo "找不到模型路径。用法: MODEL=/path/qwen3.6.gguf bash opena_experiment.sh"
  exit 1
fi
[ -f "$MODEL" ] || { echo "模型文件不存在: $MODEL"; exit 1; }
echo "模型: $MODEL"

mkdir -p "$WORK"; cd "$WORK"

# ---------- 1. clone 完整 llama.cpp ----------
if [ ! -d llama.cpp/.git ]; then
  echo "[1/6] clone llama.cpp ..."
  git clone --quiet https://github.com/ggml-org/llama.cpp.git llama.cpp || {
    git clone --quiet git@github.com:ggml-org/llama.cpp.git llama.cpp || exit 1; }
else
  echo "[1/6] llama.cpp 已存在, 跳过"
fi
cd llama.cpp

# ---------- 2. 合体: 对位拷入 SparkMoE 零件(先 diff) ----------
echo "[2/6] 合体有人件 ..."
declare -A MAP=(
  ["llama-graph.cpp"]="src/llama-graph.cpp"
  ["llama-kv-cache.cpp"]="src/llama-kv-cache.cpp"
  ["llama-kv-cache.h"]="src/llama-kv-cache.h"
  ["llama-kv-cells.h"]="src/llama-kv-cells.h"
)
for src_rel in "${!MAP[@]}"; do
  src="$REPO_SPARK/$src_rel"; dst="$MAP[$src_rel]"
  [ -f "$src" ] || { echo "  跳过(缺失): $src_rel"; continue; }
  if [ -f "$dst" ]; then
    diff_lines=$(diff "$src" "$dst" 2>/dev/null | wc -l)
    echo "  $src_rel -> $dst (diff $diff_lines 行)"
    if [ "$diff_lines" -gt 50 ] && [ "$diff_lines" -lt 200000 ]; then
      echo "    diff 中等, 直接覆盖(SparkMoE 的 llama-graph 是完整版)"
      cp "$src" "$dst"
    elif [ "$diff_lines" -ge 200000 ]; then
      echo "    diff 巨大, 停止! 请人工检查: $src_rel 版本不匹配"
      exit 1
    else
      cp "$src" "$dst"
    fi
  else
    echo "  $src_rel -> $dst (新文件, 直接拷)"
    mkdir -p "$(dirname "$dst")"; cp "$src" "$dst"
  fi
done

# moe-paging 目录
if [ -d "$REPO_SPARK/moe-paging" ]; then
  echo "  moe-paging/ -> src/moe-paging/ (整目录)"
  mkdir -p src/moe-paging
  cp "$REPO_SPARK"/moe-paging/* src/moe-paging/
fi

# ---------- 3. 补丁 ----------
echo "[3/6] apply 补丁 ..."
if [ -f "$REPO_SPARK/patches/c-tier-pin.patch" ]; then
  git apply "$REPO_SPARK/patches/c-tier-pin.patch" 2>/dev/null \
    && echo "  c-tier-pin.patch OK" || echo "  c-tier-pin.patch 已合或跳过"
fi
echo "  提醒: TRACE-COLLECTION.md 的 remap_callback + --moe-trace 需人工加(见说明), 若尚未加, trace 采集会无输出。"

# ---------- 4. 编译 ----------
if [ $SKIP_BUILD -eq 0 ]; then
  echo "[4/6] cmake build (llama-cli, CPU) ..."
  cmake -B build -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF -DLLAMA_CUDA=OFF -DGGML_OPENMP=ON 2>&1 | tail -2
  cmake --build build -j"$(nproc)" --target llama-cli 2>&1 | tail -5
  [ -x build/bin/llama-cli ] || { echo "编译失败, 查上方报错"; exit 1; }
  echo "  编译成功: build/bin/llama-cli"
else
  echo "[4/6] 跳过编译(--skip-build)"
fi

# ---------- 5. 冒烟 ----------
echo "[5/6] 冒烟测试 (生成 8 tokens) ..."
build/bin/llama-cli -m "$MODEL" -p "hi" -n 8 -ngl 0 2>&1 | tail -6

# ---------- 6. 采 trace ----------
echo "[6/6] 采集 2 条独立 trace ..."
mkdir -p "$WORK/traces"
for kind in code chat; do
  case $kind in
    code) PROMPT="Write a C program to sum an array." ;;
    chat) PROMPT="Explain what a MoE model is. Keep it short." ;;
  esac
  echo "  -- trace_$kind.jsonl ..."
  build/bin/llama-cli -m "$MODEL" -p "$PROMPT" -n 128 -ngl 0 \
      --moe-trace "$WORK/traces/trace_$kind.jsonl" 2>&1 | tail -2
  ls -la "$WORK/traces/trace_$kind.jsonl" 2>/dev/null || echo "    ⚠️ 无输出: --moe-trace 未生效, 需加 remap_callback 补丁"
done

echo
echo "完成。trace 位置: $WORK/traces/"
echo "把 $WORK/traces/*.jsonl 回传后即可离线分析(profile_trace.py / sram_stats.py)"