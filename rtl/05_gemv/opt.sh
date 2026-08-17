#!/data/data/com.termux/files/usr/bin/bash
# opt.sh — 05_gemv 一键面积报告（严谨口径，可复现）
#
# 口径（对齐 OpenLane 流片流程）：
#   OpenLane SYNTH_NO_FLAT 默认 0 = 综合时 flatten（见 OpenLane 文档）。
#   因此"能流片"的面积必须用 flatten 后结果，reharden.py 也是读 yosys
#   "Number of cells:" 行。非 flatten 的 5408 cells 是误导口径，不使用。
#
# 命令全走：synth → flatten → dfflibmap → abc（可加面积脚本）。
# 报告 = 各版本 flatten 后面积矩阵 + 门级构成 top。
#
# 用法: ./opt.sh              # 全部（面积矩阵 + 构成）
#       ./opt.sh matrix       # 只跑版本面积矩阵
#       ./opt.sh top          # 只跑门级构成
set -e
cd "$(dirname "$0")"

LIB=sky130.tt.lib
[ -f "$LIB" ] || { echo "缺 $LIB"; exit 1; }

# 版本清单：全 flatten 口径
readlib="read_liberty -lib $LIB"
VERSIONS=(
  "tt_um_periph_mac|tt_um_periph_mac|tt_um_periph_mac.v periph_mac.v periph_scale.v f32_add.v"
  "periph_mac 纯核|periph_mac|periph_mac.v periph_scale.v f32_add.v"
)

stats_cells() {   # <log> → flatten 后累加 sky130 cell 明细（正确逻辑口径）
    python3 - "$1" <<'PY'
import re,sys
lines=open(sys.argv[1]).read()
# flatten 后 stat 无子模块层次，cell 明细即真实逻辑。取最后一段含 sky130 的块累加。
blocks=[b for b in re.split(r'\n=== \d+\.', lines) if 'sky130_fd_sc_hd__' in b]
last=blocks[-1] if blocks else ''
tot=0
for line in last.splitlines():
    m=re.match(r'\s*(\d+)\s+(sky130_fd_sc_hd__\S+)\s*$', line.rstrip())
    if m: tot+=int(m.group(1))
print(tot)
PY
}

synth_flat() {    # <label> <top> <files> <script> <log>
    local label=$1 top=$2 files=$3 script=$4 log=$5
    timeout 90 yosys -p "$readlib; read_verilog $files; synth -top $top; \
flatten; dfflibmap -liberty $LIB; abc -liberty $LIB $script; stat" > "$log" 2>&1 \
      && stats_cells "$log" \
      || { echo 0; }
}

matrix() {
    echo "== 面积矩阵（flatten 口径，对齐 OpenLane SYNTH_NO_FLAT=0）=="
    echo "  1 tile ≈ 1000 门（TinyTapeout 官方，TT04-TT10）"
    printf "  %-22s %10s\n" "版本" "cells"
    for v in "${VERSIONS[@]}"; do
        label=${v%%|*}; rest=${v#*|}; top=${rest%%|*}; files=${rest#*|}
        n=$(synth_flat "$label" "$top" "$files" "" "opt_m_$(echo $label|tr -cd 'a-z0-9').log")
        printf "  %-22s %10s\n" "$label" "$n"
    done
    # 附件：面积压缩脚本（strash + &dch -f + &nf，兼容当前内嵌 ABC）
    n=$(synth_flat "tt_um + 面积脚本" "tt_um_periph_mac" \
        "tt_um_periph_mac.v periph_mac.v periph_scale.v f32_add.v" \
        "-script $(pwd)/area2.abc.script" opt_m_flat_area.log)
    printf "  %-22s %10s\n" "tt_um + 面积脚本" "$n"
}

top() {
    echo "== 门级构成 top 12（flatten 口径）=="
    n=$(synth_flat "constit" "tt_um_periph_mac" \
        "tt_um_periph_mac.v periph_mac.v periph_scale.v f32_add.v" "" opt_top.log)
    python3 - opt_top.log <<'PY'
import re,sys
from collections import Counter
c=Counter()
for line in open(sys.argv[1]):
    m=re.match(r'\s*(\d+)\s+(sky130_fd_sc_hd__(\S+?)_\d)\s*$', line.rstrip())
    if m: c[m.group(3)]+=int(m.group(1))
tot=sum(c.values())
print(f'  total cells = {tot}')
for cell,n in c.most_common(12):
    print(f'  {cell:12s} {n:6d}  ({100.0*n/tot:.1f}%)')
PY
}

bf16() {   # 版本 B（流片目标）面积：tt_um_bf16，目标 ≤1000 cells（1 tile）
    echo "== 版本 B 面积（flatten 口径，1 tile ≈ 1000 门）=="
    n=$(synth_flat "tt_um_bf16" "tt_um_bf16" \
        "tt_um_bf16.v periph_mac_bf16.v periph_scale_bf16.v bf16_add.v" "" opt_bf16.log)
    printf "  %-22s %10s\n" "tt_um_bf16" "$n"
}

case "${1:-all}" in
  matrix) matrix ;;
  top)    top ;;
  bf16)   bf16 ;;
  all|*)  matrix; echo; top ;;
esac