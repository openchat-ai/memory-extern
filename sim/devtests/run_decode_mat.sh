#!/bin/bash
# run_decode_mat.sh — M36 可复跑回归门: decode_auto 全矩阵 (PROFILE×SEED×HALF×TN×FAULT)
# 用法: bash sim/devtests/run_decode_mat.sh [OUTDIR]
#   OUTDIR 默认 /data/data/com.termux/files/usr/tmp/opencode
# 退出: 0 = 全部 PASS/CAUGHT, 非零 = 有 FAIL 或 REDTEAM ESCAPE
set -u
OUT=${1:-/data/data/com.termux/files/usr/tmp/opencode}
mkdir -p "$OUT"
ROOT=/data/data/com.termux/files/home/sram
RTL=( rtl/41_decode_auto/decode_auto_tb.v rtl/40_head_vprune/head_vprune.v \
      rtl/38_vocab_prune/vocab_prune.v rtl/35_output_head/output_head.v \
      rtl/36_route_asm/route_asm.v rtl/33_router_sel/router_sel.v rtl/34_assembler/assembler.v \
      rtl/26_sched_exec/sched_exec.v rtl/19_gemv_rail/gemv_rail_ctl.v \
      rtl/18_sram_pool_arb/sram_pool_arb.v rtl/20_attn_window/attn_window.v \
      rtl/21_attn_inner/attn_inner_ctl.v rtl/05_gemv/gemv_array_128.v )

# 表: PROFILE SEED HALF TN PROBEON FAULT 期望("PASS"|"CAUGHT")
run_row() {
  local prof=$1 seed=$2 half=$3 tn=$4 probeon=$5 fault=$6 want=$7
  local tag=P${prof}S${seed}H${half}T${tn}F${fault}n${probeon}
  local out="$OUT/mat_$tag.out"
  ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb \
      -P decode_auto_tb.PROFILE=$prof -P decode_auto_tb.SEED=$seed -P decode_auto_tb.HALF=$half \
      -P decode_auto_tb.TN=$tn -P decode_auto_tb.PROBEON=$probeon -P decode_auto_tb.FAULT=$fault \
      -o "$out" "${RTL[@]}" ) 2>/dev/null || { echo "COMPILE-FAIL $tag"; return 2; }
  timeout 400 vvp "$out" > "$OUT/mat_$tag.log" 2>&1 || true
  local log="$OUT/mat_$tag.log"
  if [ "$want" = "PASS" ]; then
    if grep -q "ALL PASS" "$log"; then echo "PASS   $tag"; return 0; fi
    if grep -q "REDTEAM ESCAPE" "$log"; then echo "ESCAPE $tag"; return 3; fi
    echo "FAIL   $tag"; return 1
  else # CAUGHT: 期望某断言抓住注入
    if grep -qE "FAIL (GEMM|o |t=5 )|FAIL GEMM 对账" "$log"; then echo "CAUGHT $tag"; return 0; fi
    if grep -q "ALL PASS" "$log"; then echo "MISSED $tag (注入未触发, ALL PASS)"; return 1; fi
    if grep -q "REDTEAM ESCAPE" "$log"; then echo "ESCAPE $tag"; return 3; fi
    echo "UNKNOWN $tag"; return 1
  fi
}

declare -i rc=0
# 主矩阵
for row in "0 0 5 12 1 0 PASS" "1 0 5 12 1 0 PASS" "2 0 5 12 1 0 PASS" \
           "4 0 5 12 1 0 PASS" "5 0 5 12 1 0 PASS" "6 0 5 12 1 0 PASS" \
           "8 0 5 12 1 0 PASS" "9 0 5 12 1 0 PASS" \
           "0 1 5 12 1 0 PASS" "0 2 5 12 1 0 PASS" "0 3 5 12 1 0 PASS" \
           "0 0 9 12 1 0 PASS" "2 1 5 12 1 0 PASS" "4 3 5 12 1 0 PASS"; do
  run_row $row; rc+=$?
done
# 疲劳长跑
run_row 0 0 5 60 0 0 PASS; rc+=$?
run_row 2 0 5 30 0 0 PASS; rc+=$?
# 交叉维度角点
run_row 4 2 9 12 1 0 PASS; rc+=$?
run_row 8 0 9 12 1 0 PASS; rc+=$?
run_row 8 1 5 30 1 0 PASS; rc+=$?
# 断言红队
run_row 0 0 5 12 1 1 CAUGHT; rc+=$?
run_row 0 0 5 12 1 2 CAUGHT; rc+=$?
run_row 0 0 5 12 1 3 CAUGHT; rc+=$?

echo "===================="
echo "decode_auto 回归门: rc=$rc (0=全绿)"
exit $(( rc ? 1 : 0 ))