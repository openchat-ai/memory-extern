#!/bin/bash
# run_decode_k_sweep.sh — K 轴扫描 (M115)
#   P0 × NK{5,8,12,16} × F1/F2/F3 (期望CAUGHT); FKXG×K 交叉 P11×K{5,12,16}×F2/F4
#   完证头部提取数轴覆盖。
set -u
OUT=${1:-/data/data/com.termux/files/usr/tmp/opencode}
ROOT=/data/data/com.termux/files/home/sram
RTL=( $ROOT/rtl/41_decode_auto/decode_auto_tb.v $ROOT/rtl/40_head_vprune/head_vprune.v \
      $ROOT/rtl/38_vocab_prune/vocab_prune.v $ROOT/rtl/35_output_head/output_head.v \
      $ROOT/rtl/36_route_asm/route_asm.v $ROOT/rtl/33_router_sel/router_sel.v $ROOT/rtl/34_assembler/assembler.v \
      $ROOT/rtl/26_sched_exec/sched_exec.v $ROOT/rtl/19_gemv_rail/gemv_rail_ctl.v \
      $ROOT/rtl/18_sram_pool_arb/sram_pool_arb.v $ROOT/rtl/20_attn_window/attn_window.v \
      $ROOT/rtl/21_attn_inner/attn_inner_ctl.v $ROOT/rtl/05_gemv/gemv_array_128.v )
declare -i rc=0 np=0 nc=0 nf=0 nd=0
run() {
  local p=$1 k=$2 fl=$3 fk=$4
  local tag=P${p}K${k}F${fl}X${fk}
  ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb \
      -P decode_auto_tb.PROFILE=$p -P decode_auto_tb.NK=$k -P decode_auto_tb.FAULT=$fl -P decode_auto_tb.FKXG_P=$fk \
      -o "$OUT/k_$tag.out" "${RTL[@]}" ) >/dev/null 2>&1 || { echo "CFAIL $tag"; nf+=1; return; }
  local log=$(timeout 300 vvp "$OUT/k_$tag.out" 2>&1)
  if echo "$log" | grep -qE 'FAIL.*(GEMM|o |watchdog|round |exec |rail |裕量|漏出窗|窗界失配|窗内top-K)'; then
    echo "CAUGHT $tag"; nc+=1
  elif echo "$log" | grep -q "ALL PASS"; then echo "MISSED $tag"; nf+=1
  elif echo "$log" | grep -q "多样性\|多样化"; then echo "DEGEN  $tag"; nd+=1
  else echo "OTHER  $tag"; nf+=1; fi
  rm -f "$OUT/k_$tag.out"
}
# P0 基线 K 轴
for k in 5 8 12 16; do
  run 0 $k 1 0
  run 0 $k 2 0
  run 0 $k 3 0
done
# P11 FKXG K 轴
for k in 5 12 16; do
  run 11 $k 2 1
  run 11 $k 4 1
done
# P2 节流 FKXG K 轴
for k in 5 16; do
  run 2 $k 3 1
  run 2 $k 5 1
done
echo "===================="
echo "K 浸泡: CAUGHT=$nc MISSED=$nf DEGEN=$nd rc=$rc (0=全绿)"
exit $(( (rc||nf) ? 1 : 0 ))