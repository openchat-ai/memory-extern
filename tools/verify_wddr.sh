#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# verify_wddr.sh — 离线一键验证（无网络依赖）
#
# 用法:
#   tools/verify_wddr.sh            # 完整: lint(~1min) + 构建(3-6min) + 仿真(1min)
#   tools/verify_wddr.sh quick      # 只 lint（约1分钟，有进度点不会卡住）
#   tools/verify_wddr.sh sim        # 跳过 lint
#
# 每一步都有进度点输出；完整日志在 /data/data/com.termux/files/usr/tmp/opencode/
# 汇总追加到仓库根目录 verify_report.txt
# =============================================================================
set -u
cd "$(dirname "$0")/.."
LOGDIR=/data/data/com.termux/files/usr/tmp/opencode
mkdir -p $LOGDIR
REPORT=verify_report.txt
MODE="${1:-full}"

echo "[$(date '+%H:%M:%S')] verify_wddr 启动 mode=$MODE"
{ echo "=============================================="; 
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] mode=$MODE"; } >> $REPORT

say(){ echo "  $*" >> $REPORT; echo "  $*"; }

# 后台执行命令，每10秒打一个进度点(带已耗时秒数)，结束后报状态和耗时
run_bg(){
    local name="$1"; shift
    local t0=$(date +%s) logf="$LOGDIR/${name}.log"
    "$@" > "$logf" 2>&1 &
    local pid=$!
    printf "  [%s] 运行中 " "$name"
    while kill -0 $pid 2>/dev/null; do
        sleep 10
        printf "%ds " $(( $(date +%s) - t0 ))
    done
    wait $pid; local rc=$?
    local dt=$(( $(date +%s) - t0 ))
    if [ $rc -eq 0 ]; then echo "| 完成 ${dt}s ✓"
    else echo "| 失败 rc=$rc (${dt}s)"; fi
    return $rc
}

LINT=SKIP BUILD=SKIP SIM=—

# ---------- 1. LINT ----------
if [ "$MODE" != "sim" ]; then
    echo "[1/3] lint (~1分钟):"
    if run_bg lint tools/lint_wddr.sh; then LINT=PASS; say "lint: PASS"
    else LINT=FAIL
        say "lint: FAIL 前5条错误:"
        grep "%Error" $LOGDIR/lint.log | head -5 | sed 's/^/    /' | tee -a $REPORT
    fi
fi

# ---------- 2. BUILD ----------
if [ "$MODE" != "quick" ]; then
    BIN=obj_dir_smoke/sim_wddr_smoke
    need=1
    NEWEST=$(find rtl/10_phy_final \( -name "*.sv" -o -name "*.v" -o -name "*.vh" \) \
              -newer "$BIN" 2>/dev/null | head -1)
    [ -x "$BIN" ] && [ -z "$NEWEST" ] && need=0
    if [ $need = 1 ]; then
        echo "[2/3] verilator 构建 (首次约3-6分钟):"
        if run_bg build tools/sim_wddr.sh --build-only; then BUILD=PASS
        else
            BUILD=FAIL
            say "build: FAIL 前5条:"
            grep -E "^%Error" $LOGDIR/build.log | head -5 | sed 's/^/    /' | tee -a $REPORT
            echo "RESULT: BUILD FAILED" >> $REPORT; exit 1
        fi
    else
        echo "[2/3] build: SKIP（二进制最新）"; BUILD=CACHED
    fi
fi

# ---------- 3. RUN ----------
if [ "$MODE" != "quick" ] && [ -x obj_dir_smoke/sim_wddr_smoke ]; then
    echo "[3/3] 12ms 冒烟仿真 (~1分钟):"
    ./obj_dir_smoke/sim_wddr_smoke +RAMDIR=rtl/10_phy_final/sw/tests/wddr_boot/ramfiles \
        > $LOGDIR/run.log 2>&1
    pc=$(grep -oE "pc_changes=[0-9]+" $LOGDIR/run.log | head -1 | cut -d= -f2)
    ireq=$(grep -oE "instr_req=[0-9]+" $LOGDIR/run.log | head -1 | cut -d= -f2)
    chphy=$(grep -oE "chphy=[01]\([0-9]+\)" $LOGDIR/run.log | tail -1)
    rdval=$(grep -oE "rdval=[0-9]+" $LOGDIR/run.log | tail -1 | cut -d= -f2)
    verdict=$(grep "SMOKE RESULT" $LOGDIR/run.log | head -1 | sed 's/^ *//')
    say "MCU : pc_changes=${pc:-0} instr_req=${ireq:-0}"
    say "时钟: chphy=${chphy:-无} rd_valid=${rdval:-0}"
    say "判定: ${verdict:-无结果行}"
    [ "${rdval:-0}" -gt 0 ] 2>/dev/null && say ">>> 数据通路闭环! <<<"
fi

{
    echo "SUMMARY: lint=$LINT build=$BUILD"
    echo "=============================================="
} >> $REPORT
echo "完成。日志: $LOGDIR ; 历史: $PWD/$REPORT"
