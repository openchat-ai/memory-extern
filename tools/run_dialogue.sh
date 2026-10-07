#!/data/data/com.termux/files/usr/bin/bash
# 端到端对话质量: 同 prompt 多格式对照生成
MODEL="$1"; OUT="$2"
PROMPT='请直接回答，不要输出思考过程：用一句话说明什么是向量量化。'
timeout 260 taskset -c 4-8 llama-cli -m "$MODEL" -p "$PROMPT" -n 200 -c 512 -st --no-display-prompt 2>"$OUT.log" | sed -n '/^.*> /d' > "$OUT.txt"
CODE=$?
# 剥离 llama-cli 的绘图 banner / 加载条
sed -i '/^Loading model/d' "$OUT.txt"
echo "exit=$CODE bytes=$(wc -c < "$OUT.txt")"
