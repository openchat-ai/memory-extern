#!/usr/bin/env bash
# WSL2 执行清单: 张量分解可行性实测 (§15 路径2)
# 用法: bash tools/wsl2_decompose_plan.sh [phase]
#   phase: 1=环境 2=smol快速验证 3=真K3全量测绘(需大内存/多卡)
set -euo pipefail
PHASE="${1:-1}"
echo "== Phase $PHASE: WSL2 张量分解实测 =="

PH1() {
  echo "[1/3] 安装环境 (WSL2/Ubuntu)"
  echo '  请确认: 有 GPU + CUDA, 磁盘 >50GB 空闲'
  echo '  sudo apt update && sudo apt install -y python3-pip git'
  echo '  python3 -m pip install torch --index-url https://download.pytorch.org/whl/cu126'
  echo '  python3 -m pip install safetensors numpy tqdm'
  echo '  (若做蒸馏再用: pip install -e ./distillkit)'
  echo '  验证: python3 -c "import torch;print(torch.__version__, torch.cuda.is_available())"'
}

PH2() {
  echo "[2/3] smol-kimi-k3(49M) 快速验证 — 本机就能出判定数据"
  echo '  ## 2a. 拉源码+权重'
  echo '  git clone https://github.com/cneuralnetwork/smol-kimi-k3 && cd smol-kimi-k3'
  echo '  pip install -r requirements.txt'
  echo '  mkdir pretrained/smol-kimi-k3'
  echo '  gh release download v0.1.0-tinystories --repo cneuralnetwork/smol-kimi-k3 --dir pretrained/smol-kimi-k3'
  echo '  # 仓库里架构: H=5, HD=64, hidden=320, 13层'
  echo ''
  echo '  ## 2b. 跑张量分解映射器(关键! 出判定)'
  echo '  cd <本sram仓库>   # 把 kda_tensor_decompose.py 拷过来或指路径'
  echo '  python3 tools/kda_tensor_decompose.py --ckpt ../smol-kimi-k3/pretrained/smol-kimi-k3/model.safetensors --arch smol --json map.json --csv map.csv'
  echo '  # 看输出: 每矩阵 rank90率 + 头结构重构误差 head_err_R4'
  echo '  #   判定: rank90率<50% 且 head_err_R4<0.1 => 头共享/低秩 => 张量分解可行(§13)'
  echo '  #         rank90率≈100% 且 head_err_R4大    => 满秩墙(§12) => 走路径3'
  echo ''
  echo '  ## 2c. (可选)用蒸馏验证端到端不掉点'
  echo '  #   若 2b 判定可行, 用 kimi-k3-tiny/自蒸馏小替身看选路精度'
}

PH3() {
  echo "[3/3] 真 K3 全量测绘 (需 ≥模型体积内存 或 分layer/分段)"
  echo '  真 K3 (2.8T) 权重太大, 建议:'
  echo '    方法A: 只加载前~20层的权重子集(每层 ~0.95GB×KDA, 20层≈19GB)'
  echo '    方法B: sglang 已加载权重时, 在内存里直接抓 张量(np) 喂给测绘器'
  echo '  命令(方法A, 用 safetensors切片):'
  echo '    python3 tools/kda_tensor_decompose.py --ckpt <K3-layer-slice.safetensors> --arch k3 --json k3_map.json'
  echo '  关注: q_proj [7168->12288] 96头×128 的 rank90 / 头共享误差 —— 这决定整条线'
  echo '    => qkv 若近无损可压: 张量分解产品可行(§17), 走§15路径1全模型'
  echo '    => qkv 若满秩墙: 回§15路径3(训router)'
}

case "$PHASE" in
  1) PH1 ;;
  2) PH2 ;;
  3) PH3 ;;
  *) echo "phase must be 1|2|3"; exit 1 ;;
esac
echo "== done =="
