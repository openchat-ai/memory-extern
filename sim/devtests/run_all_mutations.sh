#!/bin/bash
# run_all_mutations.sh — 突变击杀可重放回归 (M82)
#   对当前 RTL 源重放全部 13 株击杀样本; 任一株未击杀 (LIVE) 即回归失败。
#   CAUGHT 判定与 run_decode_mat.sh 的族匹配语义一致。
# 使用: bash run_all_mutations.sh [OUT_DIR]
set -u
OUT=${1:-/data/data/com.termux/files/usr/tmp/opencode}
ROOT=/data/data/com.termux/files/home/sram
MUTR=$ROOT/sim/devtests/mut
declare -i rc=0 kills=0
RTL=(rtl/41_decode_auto/decode_auto_tb.v rtl/40_head_vprune/head_vprune.v \
     rtl/38_vocab_prune/vocab_prune.v rtl/35_output_head/output_head.v \
     rtl/36_route_asm/route_asm.v rtl/33_router_sel/router_sel.v \
     rtl/34_assembler/assembler.v rtl/26_sched_exec/sched_exec.v \
     rtl/19_gemv_rail/gemv_rail_ctl.v rtl/18_sram_pool_arb/sram_pool_arb.v \
     rtl/20_attn_window/attn_window.v rtl/21_attn_inner/attn_inner_ctl.v \
     rtl/05_gemv/gemv_array_128.v)

# kill(样本名, 目标源, PROF参数...)
kill() {
  local name=$1 rep=$2; shift 2
  local rtl=() f
  for f in "${RTL[@]}"; do
    if [ "$f" = "$rep" ]; then rtl+=("$MUTR/$name.v"); else rtl+=("$f"); fi
  done
  ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb "$@" -o "$OUT/mutkill_$name.out" "${rtl[@]}" ) >/dev/null 2>&1 || { echo "CFAIL  $name"; rc+=1; return; }
  if timeout 300 vvp "$OUT/mutkill_$name.out" 2>&1 |
       grep -qE 'FAIL.*(GEMM|o |watchdog|round |exec |rail |裕量|漏出窗|窗界失配|窗内top-K|acc扰动)'; then
    echo "KILL   $name"; kills+=1
  else
    echo "LIVE   $name"; rc+=1
  fi
}

kill M48_oh_cmpge rtl/35_output_head/output_head.v
kill M48_oh_tieord rtl/35_output_head/output_head.v
kill M48_asm_trunc rtl/34_assembler/assembler.v
kill M63_vp_lbwofs rtl/40_head_vprune/head_vprune.v -P decode_auto_tb.PROFILE=11
kill M63_vp_ubwc    rtl/40_head_vprune/head_vprune.v -P decode_auto_tb.PROFILE=11
kill M73_vp_tie     rtl/38_vocab_prune/vocab_prune.v
kill M73_aw_addr    rtl/20_attn_window/attn_window.v
kill M74_gemv_add   rtl/05_gemv/gemv_array_128.v
kill M75_rs_lt      rtl/33_router_sel/router_sel.v
kill M76_ai_add     rtl/21_attn_inner/attn_inner_ctl.v
kill M79_sp_eq      rtl/18_sram_pool_arb/sram_pool_arb.v
kill M80_sc_addr    rtl/26_sched_exec/sched_exec.v
kill M82_rail_fcnt  rtl/19_gemv_rail/gemv_rail_ctl.v

echo "===================="
echo "突变击杀回归: KILL=$kills LIVE/CFAIL=$((rc)) 总计=$((kills+rc)) rc=$rc (0=13/13全击杀)"
exit $(( rc ? 1 : 0 ))