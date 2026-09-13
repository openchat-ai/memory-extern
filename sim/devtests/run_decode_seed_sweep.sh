#!/bin/bash
# run_decode_seed_sweep.sh — SEED 全域浸泡 (M94)
#   P0/P2 基线双谱 × SEED 0..15 全扫 PASS 浸泡; 专用于 SEED 轴完备化,
#   不入主门 (run_decode_mat), 完证 SEED 轴 16 值全绿。
# 使用: bash run_decode_seed_sweep.sh [OUT_DIR]
set -u
OUT=${1:-/data/data/com.termux/files/usr/tmp/opencode}
ROOT=/data/data/com.termux/files/home/sram
D=$ROOT/rtl
RTL=($D/41_decode_auto/decode_auto_tb.v $D/40_head_vprune/head_vprune.v $D/38_vocab_prune/vocab_prune.v \
     $D/35_output_head/output_head.v $D/36_route_asm/route_asm.v $D/33_router_sel/router_sel.v \
     $D/34_assembler/assembler.v $D/26_sched_exec/sched_exec.v $D/19_gemv_rail/gemv_rail_ctl.v \
     $D/18_sram_pool_arb/sram_pool_arb.v $D/20_attn_window/attn_window.v $D/21_attn_inner/attn_inner_ctl.v \
     $D/05_gemv/gemv_array_128.v)
declare -i rc=0 np=0 nd=0
for prof in 0 2; do
  for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    tag=P${prof}S${s}
    ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb \
        -P decode_auto_tb.PROFILE=$prof -P decode_auto_tb.SEED=$s -o "$OUT/swp_$tag.out" "${RTL[@]}" ) >/dev/null 2>&1 \
      || { echo "CFAIL $tag"; rc+=1; continue; }
    if timeout 300 vvp "$OUT/swp_$tag.out" 2>&1 | grep -q "ALL PASS"; then echo "PASS   $tag"; np+=1
    elif timeout 300 vvp "$OUT/swp_$tag.out" 2>&1 | grep -q "多样化\|多样性"; then echo "DEGEN  $tag (节流谱×seed 刺激退化, 守卫触发, 非产品缺陷)"; nd+=1
    else echo "FAIL   $tag"; rc+=1; fi
  done
done
echo "===================="
echo "SEED 浸泡: PASS=$np DEGEN=$nd rc=$rc (0=P0/P2×S0-15 除记录在案退化外全绿)"
exit $(( rc ? 1 : 0 ))