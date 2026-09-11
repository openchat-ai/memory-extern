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
  local name=$1 top=$2; shift 2
  local out="$OUT/reg_$name.out"
  if iverilog -g2012 -s "$top" -o "$out" "$@" > /dev/null 2>&1; then
    local n=$(timeout 300 vvp "$out" 2>&1 | grep -cE "ALL PASS|PASS")
    if [ "$n" -ge 1 ]; then echo "PASS   $name"; else echo "NOMARK $name"; rc+=1; fi
  else echo "CFAIL  $name"; rc+=2; fi
}
D=rtl
check M19 output_head_tb $D/35_output_head/output_head_tb.v $D/35_output_head/output_head.v
check M21 p2_loop_tb $D/37_p2_loop/p2_loop_tb.v $D/37_p2_loop/p2_loop.v $D/37_p2_loop/engine_stub.v \
      $D/36_route_asm/route_asm.v $D/33_router_sel/router_sel.v $D/34_assembler/assembler.v $D/35_output_head/output_head.v
check M23 route_asm_exec_tb $D/39_route_asm_exec/route_asm_exec_tb.v $D/36_route_asm/route_asm.v \
      $D/33_router_sel/router_sel.v $D/34_assembler/assembler.v $D/26_sched_exec/sched_exec.v \
      $D/19_gemv_rail/gemv_rail_ctl.v $D/18_sram_pool_arb/sram_pool_arb.v $D/20_attn_window/attn_window.v \
      $D/21_attn_inner/attn_inner_ctl.v $D/05_gemv/gemv_array_128.v
check M24 head_vprune_tb $D/40_head_vprune/head_vprune_tb.v $D/40_head_vprune/head_vprune.v \
      $D/38_vocab_prune/vocab_prune.v $D/35_output_head/output_head.v $D/36_route_asm/route_asm.v \
      $D/33_router_sel/router_sel.v $D/34_assembler/assembler.v $D/26_sched_exec/sched_exec.v \
      $D/19_gemv_rail/gemv_rail_ctl.v $D/18_sram_pool_arb/sram_pool_arb.v $D/20_attn_window/attn_window.v \
      $D/21_attn_inner/attn_inner_ctl.v $D/05_gemv/gemv_array_128.v
check M38-kv kv_writeback_tb $D/27_kv_writeback/kv_writeback_tb.v $D/27_kv_writeback/kv_writeback.v
check M38-kr kv_restore_tb $D/30_kv_restore/kv_restore_tb.v $D/30_kv_restore/kv_restore.v

echo "===================="
echo "全链回归: rc=$rc (0=全绿)"
exit $(( rc ? 1 : 0 ))