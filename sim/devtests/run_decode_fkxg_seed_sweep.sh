#!/bin/bash
# run_decode_fkxg_seed_sweep.sh — FKXG×SEED 全相位轴浸泡 (M119)
#   P11(FKXG远峰) × SEED 0..15 × F0(期望PASS)/F2(期望CAUGHT)
#   完证远峰×seed 相位轴系统覆盖 (此前仅抽样 S0/5/7/11)。
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
  local s=$1 fl=$2
  local tag=S${s}F${fl}
  [ "$fl" = 0 ] && local want=PASS || local want=CAUGHT
  ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb \
      -P decode_auto_tb.PROFILE=11 -P decode_auto_tb.SEED=$s -P decode_auto_tb.FAULT=$fl \
      -o "$OUT/fx_$tag.out" "${RTL[@]}" ) >/dev/null 2>&1 || { echo "CFAIL $tag"; nf+=1; return; }
  local log=$(timeout 300 vvp "$OUT/fx_$tag.out" 2>&1)
  if [ "$want" = PASS ]; then
    if echo "$log" | grep -q "ALL PASS"; then echo "PASS   $tag"; np+=1
    elif echo "$log" | grep -q "多样性\|多样化"; then echo "DEGEN  $tag"; nd+=1
    else echo "FAIL   $tag"; nf+=1; fi
  else
    if echo "$log" | grep -qE 'FAIL.*(GEMM|o |watchdog|round |exec |rail |裕量|漏出窗|窗界失配|窗内top-K)'; then echo "CAUGHT $tag"; nc+=1
    elif echo "$log" | grep -q "ALL PASS"; then echo "MISSED $tag"; nf+=1
    elif echo "$log" | grep -q "多样性\|多样化"; then echo "DEGEN  $tag"; nd+=1
    else echo "OTHER  $tag"; nf+=1; fi
  fi
  rm -f "$OUT/fx_$tag.out"
}
for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  run $s 0
  run $s 2
done
echo "===================="
echo "FKXG×SEED 浸泡: PASS=$np CAUGHT=$nc DEGEN=$nd 异常=$nf rc=$rc (0=全绿)"
exit $(( (rc||nf) ? 1 : 0 ))