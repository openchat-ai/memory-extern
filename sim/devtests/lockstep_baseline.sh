#!/bin/bash
# lockstep_baseline.sh — 取 4 个 lockstep TB 的基线输出（改 _sf 之前跑一次）
# 用法: bash sim/devtests/lockstep_baseline.sh <TAG>
#   输出落盘 /tmp/dtop/<TAG>.log，供改后逐字对拍
set -u
TAG=${1:-baseline}
cd /mnt/f/sram/sram || exit 9
mkdir -p /tmp/dtop
OUT=/tmp/dtop/${TAG}.log
: > "$OUT"

declare -A P
declare -A S
declare -A DEP
P[router_sel]=rtl/33_router_sel/router_sel.v
S[router_sel]=rtl/13_mega138k/router_sel_sf.v
DEP[router_sel]=""
P[route_asm]=rtl/36_route_asm/route_asm.v
S[route_asm]=rtl/13_mega138k/route_asm_sf.v
DEP[route_asm]="rtl/33_router_sel/router_sel.v rtl/13_mega138k/router_sel_sf.v rtl/34_assembler/assembler.v"
P[attn_inner_ctl]=rtl/21_attn_inner/attn_inner_ctl.v
S[attn_inner_ctl]=rtl/13_mega138k/attn_inner_ctl_sf.v
DEP[attn_inner_ctl]=""
# head_vprune 的子模块正是 vocab_prune_sf + output_head_sf
#   -> 本 TB 传递覆盖「要改的另两个文件」是否与产品件分歧
P[head_vprune]=rtl/40_head_vprune/head_vprune.v
S[head_vprune]=rtl/13_mega138k/head_vprune_sf.v
DEP[head_vprune]="rtl/38_vocab_prune/vocab_prune.v rtl/13_mega138k/vocab_prune_sf.v rtl/35_output_head/output_head.v rtl/13_mega138k/output_head_sf.v"

for t in router_sel route_asm attn_inner_ctl head_vprune; do
  tb="sim/devtests/${t}_lockstep_tb.v"
  bin="/tmp/dtop/${t}.${TAG}.out"
  cerr="/tmp/dtop/${t}.${TAG}.cerr"
  rm -f "$bin" "$cerr"
  echo "===== $t =====" >> "$OUT"
  iverilog -g2012 -s "${t}_lockstep_tb" -o "$bin" "$tb" "${P[$t]}" "${S[$t]}" ${DEP[$t]} > "$cerr" 2>&1
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "COMPILE-FAIL rc=$rc" >> "$OUT"
    head -5 "$cerr" >> "$OUT"
    continue
  fi
  if grep -qi warning "$cerr"; then
    echo "COMPILE-WARN" >> "$OUT"
    grep -i warning "$cerr" | head -3 >> "$OUT"
  fi
  timeout 300 vvp "$bin" > "/tmp/dtop/${t}.${TAG}.vvp" 2>&1 || true
  tail -6 "/tmp/dtop/${t}.${TAG}.vvp" | tr -d '\r' >> "$OUT"
done

echo "=== 基线落盘: $OUT ==="
cat "$OUT"