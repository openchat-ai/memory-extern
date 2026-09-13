#!/bin/bash
# run_decode_vocab_sweep.sh — NVOC 轴宽浸泡 (M113)
#   P0/P2/P11 × NVOC {256,384,512,768,1024,2048} × F0(期望PASS)/F1/F2(期望CAUGHT)
#   完证词表轴宽度覆盖; 不入主门。
set -u
OUT=${1:-/data/data/com.termux/files/usr/tmp/opencode}
ROOT=/data/data/com.termux/files/home/sram
RTL=( $ROOT/rtl/41_decode_auto/decode_auto_tb.v $ROOT/rtl/40_head_vprune/head_vprune.v \
      $ROOT/rtl/38_vocab_prune/vocab_prune.v $ROOT/rtl/35_output_head/output_head.v \
      $ROOT/rtl/36_route_asm/route_asm.v $ROOT/rtl/33_router_sel/router_sel.v $ROOT/rtl/34_assembler/assembler.v \
      $ROOT/rtl/26_sched_exec/sched_exec.v $ROOT/rtl/19_gemv_rail/gemv_rail_ctl.v \
      $ROOT/rtl/18_sram_pool_arb/sram_pool_arb.v $ROOT/rtl/20_attn_window/attn_window.v \
      $ROOT/rtl/21_attn_inner/attn_inner_ctl.v $ROOT/rtl/05_gemv/gemv_array_128.v )
declare -i rc=0 np=0 nc=0 nf=0
run() {
  local p=$1 v=$2 fl=$3
  local tag=P${p}V${v}F${fl}
  [ "$fl" = 0 ] && local want=PASS || local want=CAUGHT
  ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb \
      -P decode_auto_tb.PROFILE=$p -P decode_auto_tb.NVOC=$v -P decode_auto_tb.FAULT=$fl \
      -o "$OUT/voc_$tag.out" "${RTL[@]}" ) >/dev/null 2>&1 || { echo "CFAIL $tag"; nf+=1; return; }
  local log=$(timeout 300 vvp "$OUT/voc_$tag.out" 2>&1)
  if [ "$want" = PASS ]; then
    if echo "$log" | grep -q "ALL PASS"; then echo "PASS   $tag"; np+=1
    else echo "FAIL   $tag"; nf+=1; fi
  else
    if echo "$log" | grep -qE 'FAIL.*(GEMM|o |watchdog|round |exec |rail |裕量|漏出窗|窗界失配|窗内top-K)'; then echo "CAUGHT $tag"; nc+=1
    elif echo "$log" | grep -q "ALL PASS"; then echo "MISSED $tag"; nf+=1
    else echo "OTHER  $tag"; nf+=1; fi
  fi
  rm -f "$OUT/voc_$tag.out"
}
for p in 0 2 11; do
  for v in 256 384 512 768 1024 2048; do
    run $p $v 0
    run $p $v 1
    run $p $v 2
  done
done
echo "===================="
echo "NVOC 浸泡: PASS=$np CAUGHT=$nc 异常=$nf rc=$rc (0=全绿)"
exit $(( rc || nf ? 1 : 0 ))