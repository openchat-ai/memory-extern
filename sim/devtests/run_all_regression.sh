#!/bin/bash
# run_all_regression.sh — M47 一键全链回归: decode_auto 门 + P2 算主线独立 TB 全收口
# 用法: bash sim/devtests/run_all_regression.sh [OUTDIR]
set -u
OUT=${1:-/data/data/com.termux/files/usr/tmp/opencode}
ROOT=/data/data/com.termux/files/home/sram
cd "$ROOT"
declare -i rc=0

echo "==[1/2] decode_auto 回归门 =="
bash sim/devtests/run_decode_mat.sh "$OUT" | tail -1 || rc+=$?

echo "==[2/2] P2 算主线独立 TB =="
check() {
  local name=$1 top=$2 maxtime=$3; shift 3
  local out="$OUT/reg_$name.out"
  if iverilog -g2012 -s "$top" -o "$out" "$@" > /dev/null 2>&1; then
    local n=$(timeout "$maxtime" vvp "$out" 2>&1 | grep -cE "ALL PASS|PASS")
    if [ "$n" -ge 1 ]; then echo "PASS   $name"; else echo "NOMARK $name"; rc+=1; fi
  else echo "CFAIL  $name"; rc+=2; fi
}
D=rtl
check M19 output_head_tb 300 $D/35_output_head/output_head_tb.v $D/35_output_head/output_head.v
check M21 p2_loop_tb 600 $D/37_p2_loop/p2_loop_tb.v $D/37_p2_loop/p2_loop.v $D/37_p2_loop/engine_stub.v \
      $D/36_route_asm/route_asm.v $D/33_router_sel/router_sel.v $D/34_assembler/assembler.v $D/35_output_head/output_head.v
check M23 route_asm_exec_tb 600 $D/39_route_asm_exec/route_asm_exec_tb.v $D/36_route_asm/route_asm.v \
      $D/33_router_sel/router_sel.v $D/34_assembler/assembler.v $D/26_sched_exec/sched_exec.v \
      $D/19_gemv_rail/gemv_rail_ctl.v $D/18_sram_pool_arb/sram_pool_arb.v $D/20_attn_window/attn_window.v \
      $D/21_attn_inner/attn_inner_ctl.v $D/05_gemv/gemv_array_128.v
check M24 head_vprune_tb 600 $D/40_head_vprune/head_vprune_tb.v $D/40_head_vprune/head_vprune.v \
      $D/38_vocab_prune/vocab_prune.v $D/35_output_head/output_head.v $D/36_route_asm/route_asm.v \
      $D/33_router_sel/router_sel.v $D/34_assembler/assembler.v $D/26_sched_exec/sched_exec.v \
      $D/19_gemv_rail/gemv_rail_ctl.v $D/18_sram_pool_arb/sram_pool_arb.v $D/20_attn_window/attn_window.v \
      $D/21_attn_inner/attn_inner_ctl.v $D/05_gemv/gemv_array_128.v
check M38-kv kv_writeback_tb 300 $D/27_kv_writeback/kv_writeback_tb.v $D/27_kv_writeback/kv_writeback.v
check M38-kr kv_restore_tb 300 $D/30_kv_restore/kv_restore_tb.v $D/30_kv_restore/kv_restore.v
check M59-wb wb_unified_tb 900 $D/29_wb_unified/wb_unified_tb.v $D/29_wb_unified/wb_unified.v
check M59-wd wb_diff_tb 900 $D/28_wb_diff/wb_diff_tb.v $D/28_wb_diff/wb_diff.v
check M65-loop wb2kv_loop_tb 400 $D/30_kv_restore/wb2kv_loop_tb.v $D/29_wb_unified/wb_unified.v \
      $D/30_kv_restore/kv_restore.v $D/28_wb_diff/wb_diff.v $D/27_kv_writeback/kv_writeback.v \
      $D/24_wb_flow/wb_flow.v

# M77: 真尺寸 KV 环回 (~426s) 为可选深度档: FULLREG=1 bash run_all_regression.sh
if [ "${FULLREG:-0}" = "1" ]; then
  echo "--[3/3] 真尺寸 KV 环回 (D=128, 3.4MB/token) --"
  if iverilog -g2012 -s wb2kv_loop_tb -DFULL -o "$OUT/reg_wb2kv_full.out" \
      $D/30_kv_restore/wb2kv_loop_tb.v $D/29_wb_unified/wb_unified.v $D/30_kv_restore/kv_restore.v \
      $D/28_wb_diff/wb_diff.v $D/27_kv_writeback/kv_writeback.v $D/24_wb_flow/wb_flow.v >/dev/null 2>&1; then
    if timeout 1800 vvp "$OUT/reg_wb2kv_full.out" 2>&1 | grep -qE "ALL PASS"; then
      echo "PASS   M77-full"
    else echo "FAIL   M77-full"; rc+=1; fi
  else echo "CFAIL  M77-full"; rc+=2; fi
fi

echo "===================="
echo "全链回归: rc=$rc (0=全绿)"
exit $(( rc ? 1 : 0 ))