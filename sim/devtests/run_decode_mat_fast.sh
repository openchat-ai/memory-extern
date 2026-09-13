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
  local nk=${10:-3}
  local fkxg=${11:-0}
  local prof=$1 seed=$2 half=$3 tn=$4 probeon=$5 fault=$6 voc=$7 fbpol=$8 want=$9
  local tag=P${prof}S${seed}H${half}T${tn}F${fault}n${probeon}V${voc}B${fbpol}K${nk}X${fkxg}
  local out="$OUT/mat_$tag.out"
  local cerr="$OUT/mat_$tag.cerr"
  rm -f "$out" "$OUT/mat_$tag.log" "$cerr"      # 防陈旧产物: 失编译=vvp无物=必报, 不落旧绿
  ( cd "$ROOT" && iverilog -g2012 -s decode_auto_tb \
      -P decode_auto_tb.PROFILE=$prof -P decode_auto_tb.SEED=$seed -P decode_auto_tb.HALF=$half \
      -P decode_auto_tb.TN=$tn -P decode_auto_tb.PROBEON=$probeon -P decode_auto_tb.FAULT=$fault \
      -P decode_auto_tb.NVOC=$voc -P decode_auto_tb.FBPOLY=$fbpol -P decode_auto_tb.NK=$nk \
      -P decode_auto_tb.FKXG_P=$fkxg \
-o "$out" "${RTL[@]}" > "$cerr" 2>&1 ) || { echo "COMPILE-FAIL $tag"; ncf+=1; return 2; }
   if grep -qi "warning" "$cerr"; then echo "WARN   $tag (编译警告门)"; nw+=1; return 1; fi
   timeout 400 vvp "$out" > "$OUT/mat_$tag.log" 2>&1 || true
   local log="$OUT/mat_$tag.log"
   if [ "$want" = "PASS" ]; then
     if grep -q "ALL PASS" "$log"; then
       if grep -q "窗重叠" "$log"; then
         local ovl=$(sed -n 's/.*窗重叠 \([0-9]*\)%.*/\1/p' "$log")
         if [ -n "$ovl" ] && [ "$ovl" -lt 90 ]; then echo "FAIL   $tag (窗滑移重叠率 $ovl%<90%%)"; nf+=1; return 1; fi
       fi
       echo "PASS   $tag"; np+=1; return 0; fi
     if grep -q "REDTEAM ESCAPE" "$log"; then echo "ESCAPE $tag"; ne+=1; return 3; fi
     echo "FAIL   $tag"; nf+=1; return 1
   else # CAUGHT: 期望某断言抓住注入
     if grep -qE 'FAIL.*(GEMM|o |watchdog|round |exec |rail |裕量|漏出窗|窗界失配|窗内top-K|acc扰动)' "$log"; then echo "CAUGHT $tag"; nc+=1; return 0; fi
     if grep -q "ALL PASS" "$log"; then echo "MISSED $tag (注入未触发, ALL PASS)"; nm+=1; return 1; fi
     if grep -q "REDTEAM ESCAPE" "$log"; then echo "ESCAPE $tag"; ne+=1; return 3; fi
     echo "UNKNOWN $tag"; nun+=1; return 1
   fi
}

declare -i rc=0 np=0 nc=0 nf=0 nw=0 ne=0 nm=0 ncf=0 nun=0
run_row 0 0 5 12 1 0 1024 0 PASS; rc+=$?
run_row 0 0 9 12 1 0 1024 0 PASS; rc+=$?
run_row 2 0 5 12 1 0 1024 0 PASS; rc+=$?
run_row 3 0 5 12 1 0 1024 0 PASS; rc+=$?
run_row 0 3 5 12 1 0 1024 0 PASS; rc+=$?
run_row 0 0 5 12 1 0 2048 0 PASS; rc+=$?
run_row 0 0 5 12 1 0 1024 2 PASS; rc+=$?
run_row 11 0 5 12 1 0 2048 0 PASS 16; rc+=$?
run_row 8 0 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 2 0 5 12 1 0 1024 0 PASS 3 1; rc+=$?
# 快门行: CAUGHT 族例 (GEMM / o / 窗内top-K / 窗界失配 / 远峰双错 / FKXG三叠)
run_row 0 0 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 0 10 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 4 1024 0 CAUGHT 8; rc+=$?
run_row 2 0 5 12 1 5 1024 0 CAUGHT 3 1; rc+=$?

echo "===================="
echo "decode_auto 快速回归门: PASS=$np CAUGHT=$nc WARN=$nw FAIL=$nf MISSED=$nm ESCAPE=$ne COMPILE=$ncf UNKNOWN=$nun 总计=$((np+nc+nf+nw+ne+nm+ncf+nun)) rc=$rc (0=全绿)"
exit $(( rc ? 1 : 0 ))
