#!/usr/bin/env bash
# run_true_machine.sh — 32GB CPU-only 真机双模型对标
#
# 测两台模型、同一台机器:
#   1. Dense  Qwen3.8-27B (本地已下载, Q3_K_M)  → T_DENSE
#   2. MoE    Qwen3-30B-A3B-Instruct-2507 (Q4_K_M, 自动下载) → T_SOFT
#
# 为什么要同时测:
#   - T_DENSE: dense 每 token 必须读全部 ~12-15GB 权重 → 双通道只有 ~4 t/s 量级
#     (证明"27B 缓存技术无效"是实测不是推理)
#   - T_SOFT:  MoE 只搬激活专家 → 12-30 t/s 量级, 回填 sim_compare.py 定位算力墙
#   - 对比结论一句话: dense≈4 t/s vs MoE≈25 t/s, MoE+缓存才是资源最优解.
#
# 用法:
#   bash tools/run_true_machine.sh                  # 全流程 (自动找 27B + 下/测 A3B)
#   bash tools/run_true_machine.sh --skip-download  # A3B 已下载则跳过 (仍测 27B)
#   bash tools/run_true_machine.sh --quant Q3_K_M   # 换 A3B 量化档 (默认 Q4_K_M)
#   bash tools/run_true_machine.sh --models-dir ~/models   # 模型目录换地方
#   MODEL_27B=/path/to/qwen3.8-27b-q3_K_M.gguf bash tools/run_true_machine.sh
#
# 环境变量:
#   MODELS_DIR  模型查找/存放目录 (默认 <repo>/models, 其次 ~/models 兜底)
#   MODEL_27B   显式指定 27B 文件路径 (跳过自动查找)
#   QUANT       30B-A3B 下载量化 (默认 Q4_K_M)
#
# 跨平台注意: llama.cpp 构建时需 -DLLAMA_CURL=ON 才能 -hf 直拉;
#   Windows 用户用 WSL 或改用 ollama pull + llama-bench。

set -euo pipefail

REPO_A3B="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF"
QUANT_A3B="${QUANT:-Q4_K_M}"
CTX="8192"
SWD="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${MODELS_DIR:-$SWD/models}"

SKIP_DL=0
for a in "$@"; do
  [ "$a" = "--skip-download" ] && SKIP_DL=1
done

find_local() {  # find_local <models_dir> <pattern>
  find "$1" -maxdepth 1 -type f -name "*.gguf" 2>/dev/null \
    | grep -i "$2" | head -1 || true
}

MODEL_27B="${MODEL_27B:-}"
if [ -z "$MODEL_27B" ]; then
  MODEL_27B="$(find_local "$MODELS_DIR" "27b")"
  [ -z "$MODEL_27B" ] && MODEL_27B="$(find_local "$HOME/models" "27b")"
fi

bench_speed() {  # bench_speed <model> <label> → 打印 tg/s; 输出到 stdout
  local model="$1" label="$2" out t
  out="$( { llama-bench -m "$model" -p 64 -n 128 -c "$CTX" -ngl 0 \
             --no-mmap 2>/dev/null || true; } | grep -iE '^\|\s*tg' || true )"
  echo "$out"
  t="$(echo "$out" | grep -oE '[0-9.]+' | head -1 || true)"
  if [ -z "$t" ]; then
    t="$( { yes 'ping' | head -200 | llama-cli -m "$model" -c "$CTX" -ngl 0 \
              --temp 0.7 --seed 42 -no-cnv 2>/dev/null || true; } \
          | grep -oE '[0-9.]+ tokens per second' | tail -1 \
          | grep -oE '^[0-9.]+' || true )"
  fi
  printf '%s' "$t"
}

echo "=== [1/6] 环境检查 ==="
command -v llama-bench >/dev/null && echo "  llama-bench: OK" || echo "  llama-bench: MISSING (需编译 llama.cpp 或装包)"
command -v llama-cli   >/dev/null && echo "  llama-cli:   OK"   || echo "  llama-cli:   MISSING"
command -v huggingface-cli >/dev/null && echo "  hf-cli:      OK" || echo "  hf-cli:      MISSING (可改用 llama-cli -hf 直拉)"
if ! command -v llama-bench >/dev/null; then
  echo
  echo "  llama.cpp 未找到。现在 macOS 可:  brew install llama.cpp"
  echo "  Linux:  git clone https://github.com/ggml-org/llama.cpp && "
  echo "          cd llama.cpp && cmake -B build -DLLAMA_CURL=ON -DCMAKE_BUILD_TYPE=Release"
  echo "          && cmake --build build --config Release -j --target llama-bench llama-cli"
  echo "  Windows: 用 WSL, 或在 https://github.com/ggml-org/llama.cpp/releases 拿预编译包"
  exit 1
fi

echo
echo "=== [2/6] 定位 Dense 27B (本地已下载, Q3) ==="
if [ -n "$MODEL_27B" ] && [ -f "$MODEL_27B" ]; then
  echo "  找到: $MODEL_27B"
else
  echo "  未在 '$MODELS_DIR' / '$HOME/models' 找到 *27b*.gguf."
  echo "  可设 MODEL_27B=/path/to/qwen3.8-27b-q3.gguf 后重跑; 本步跳过."
  MODEL_27B=""
fi

echo
echo "=== [3/6] MoE 30B-A3B-2507 定位/下载 ($QUANT_A3B) ==="
MODEL_A3B="$(find_local "$MODELS_DIR" "a3b\|30b")"
if [ -z "$MODEL_A3B" ] && [ $SKIP_DL -eq 0 ]; then
  if command -v llama-cli >/dev/null && llama-cli --help 2>/dev/null | grep -q 'HF_REPO'; then
    echo "  $REPO_A3B:$QUANT_A3B 由 llama.cpp 直拉 (缓存 ~/.cache/llama.cpp)"
    MODEL_A3B="hf-repo:$REPO_A3B:hf-file:$QUANT_A3B"
  else
    echo "  llama-cli 不支持 -hf 直拉, 改用 huggingface-cli 下载"
    command -v huggingface-cli >/dev/null || { echo "  且无 huggingface-cli → 手动下载到 $MODELS_DIR 再跑"; exit 2; }
    mkdir -p "$MODELS_DIR"
    huggingface-cli download "$REPO_A3B" --include "*$QUANT_A3B*.gguf" --local-dir "$MODELS_DIR"
    MODEL_A3B="$(find_local "$MODELS_DIR" "a3b\|30b")"
  fi
fi
[ -z "$MODEL_A3B" ] && { echo "  无 A3B 模型且 --skip-download → 终止."; exit 2; }
echo "  model → $MODEL_A3B"

echo
echo "=== [4/6] Dense 27B 实测 (CPU-only, ctx=$CTX) ==="
T_DENSE=""
if [ -n "$MODEL_27B" ]; then
  echo "  命令: llama-bench -m \"$MODEL_27B\" ..."
  T_DENSE="$(bench_speed "$MODEL_27B" "Dense")"
  echo "  T_DENSE ≈ ${T_DENSE:-未知} t/s  (预期 ~4 量级: 每 token 读全量权重)"
else
  echo "  27B 缺失, 跳过."
fi

echo
echo "=== [5/6] MoE 30B-A3B 实测 (CPU-only, ctx=$CTX) ==="
echo "  命令: llama-bench -m \"$MODEL_A3B\" ..."
T_SOFT="$(bench_speed "$MODEL_A3B" "MoE")"
echo "  T_SOFT ≈ ${T_SOFT:-未知} t/s  (预期 12-30 量级)"
[ -z "${T_SOFT:-}" ] && { echo "  无法测速 → 手填 T_SOFT 后跑 [6/6]"; T_SOFT="16"; }

echo
echo "=== 双模型实测对账 ==="
if [ -n "$T_DENSE" ]; then
  printf "  Dense 27B (Q3) : %6s t/s\n" "$T_DENSE"
  printf "  MoE   30B-A3B  : %6s t/s (Q4_K_M)\n" "$T_SOFT"
  awk -v d="$T_DENSE" -v m="$T_SOFT" \
    'BEGIN{ if (d+0>0) printf "  倍率: MoE/dense %.2fx\n", m/d }'
else
  printf "  MoE 30B-A3B: %s t/s\n" "$T_SOFT"
fi

echo
echo "=== [6/6] 回填 sim_compare.py (MoE 基线) ==="
[ -f "$SWD/tools/sim_compare.py" ] && python3 "$SWD/tools/sim_compare.py" --soft "$T_SOFT" || \
  { echo "  tools/sim_compare.py 缺失"; exit 2; }

echo
echo "下一步(可选)抓真实路由 trace 换 90% 命中真假:"
echo "  在 llama.cpp 评分路径 dump 每层 top-8 专家 id → expert_trace_real.txt,"
echo "  然后 python3 sim_cache2.py expert_trace_real.txt (同格式则直接跑)"
echo
echo "对账结论: T_DENSE 低 ↔ dense 缓存无效; T_SOFT>=30 → 带宽主瓶颈(芯片故事成立);"
echo "          T_SOFT<30  → 算力墙主导(芯片必须连算力一起解)."