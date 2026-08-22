#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# lint_matrix.sh — 参数矩阵 lint（离线）
# 对 ddr_phy 顶层关键参数组合逐一跑 lint，结果追加到 verify_report.txt
# 用法: tools/lint_matrix.sh        （每组约1分钟，共 N 组）
# =============================================================================
set -u
cd "$(dirname "$0")/.."
LOGDIR=/data/data/com.termux/files/usr/tmp/opencode
mkdir -p $LOGDIR

# 组名:参数覆盖（verilator -G 语法）
CONFIGS=(
  "default:"
  "secondary_phy:-GSECONDARY_PHY=1"
  "num_ch1:-GNUM_CH=1"
  "num_dq1:-GNUM_DQ=1"
)

for entry in "${CONFIGS[@]}"; do
    name="${entry%%:*}"
    opts="${entry#*:}"
    printf "[%s] lint %-14s " "$name" "$opts"
    t0=$(date +%s)
    # 复用 lint_wddr.sh 的文件列表生成，仅替换顶层参数
    tools/lint_wddr.sh $opts > $LOGDIR/lint_$name.log 2>&1
    rc=$?
    dt=$(( $(date +%s) - t0 ))
    if [ $rc -eq 0 ]; then
        echo "PASS (${dt}s)"
        echo "[$(date '+%F %T')] matrix $name $opts -> PASS" >> verify_report.txt
    else
        n=$(grep -c "%Error" $LOGDIR/lint_$name.log)
        echo "FAIL ($n errors, ${dt}s) — 见 $LOGDIR/lint_$name.log"
        echo "[$(date '+%F %T')] matrix $name $opts -> FAIL($n)" >> verify_report.txt
    fi
done
echo "矩阵完成。历史: $(pwd)/verify_report.txt"
