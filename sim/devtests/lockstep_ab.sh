#!/bin/bash
# lockstep_ab.sh — 在**同一个 WSL 会话内**做 A/B：改前 vs 改后，机械 diff
#
# 背景: /tmp 不跨 WSL 会话（全局记忆已记），所以 A 与 B 必须在同一次
#       wsl.exe 调用里跑完，产物落 /mnt/f（持久 + Windows 可见）。
#
# 做法:
#   1) 把已改的 3 份 _sf 存到 workdir
#   2) git checkout HEAD 恢复原始版本 -> 跑 4 个 lockstep -> baseline.log
#   3) 还原改动 -> 再跑 -> after.log
#   4) diff 两份日志
# 判据: diff 无输出 = 4/4 输出逐字节相同 = 改动零语义
set -u
cd /mnt/f/sram/sram || exit 9

FILES="rtl/13_mega138k/router_sel_sf.v rtl/13_mega138k/vocab_prune_sf.v rtl/13_mega138k/output_head_sf.v"
WD=/mnt/f/sram/sram/out/dtop_ab
rm -rf "$WD"; mkdir -p "$WD/orig" "$WD/mod"

for f in $FILES; do cp "$f" "$WD/mod/$(basename $f)"; done
git checkout HEAD -- $FILES || exit 8
for f in $FILES; do cp "$f" "$WD/orig/$(basename $f)"; done

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
P[head_vprune]=rtl/40_head_vprune/head_vprune.v
S[head_vprune]=rtl/13_mega138k/head_vprune_sf.v
DEP[head_vprune]="rtl/38_vocab_prune/vocab_prune.v rtl/13_mega138k/vocab_prune_sf.v rtl/35_output_head/output_head.v rtl/13_mega138k/output_head_sf.v"

run_all() {
  local dst=$1
  : > "$dst"
  for t in router_sel route_asm attn_inner_ctl head_vprune; do
    bin="$WD/${t}.$(basename $dst).out"
    cerr="$WD/${t}.$(basename $dst).cerr"
    echo "===== $t =====" >> "$dst"
    iverilog -g2012 -s "${t}_lockstep_tb" -o "$bin" \
      "sim/devtests/${t}_lockstep_tb.v" "${P[$t]}" "${S[$t]}" ${DEP[$t]} > "$cerr" 2>&1
    if [ $? -ne 0 ]; then echo "COMPILE-FAIL" >> "$dst"; head -5 "$cerr" >> "$dst"; continue; fi
    timeout 300 vvp "$bin" 2>&1 | tr -d '\r' | grep -Ei 'LOCKSTEP|mismatch|NONE|ERROR' >> "$dst"
  done
}

echo "[1/4] 跑 BASELINE (HEAD 原始版本)"
run_all "$WD/baseline.log"
echo "[2/4] 还原改动"
for f in $FILES; do cp "$WD/mod/$(basename $f)" "$f"; done
echo "[3/4] 跑 AFTER (已改版本)"
run_all "$WD/after.log"
echo "[4/4] diff"
echo "--- baseline ---"; cat "$WD/baseline.log"
echo "--- after ---";    cat "$WD/after.log"
if diff -q "$WD/baseline.log" "$WD/after.log" > /dev/null; then
  echo ""
  echo "AB-VERDICT: IDENTICAL  4/4 lockstep 输出逐字节相同 -> 改动零语义"
else
  echo ""
  echo "AB-VERDICT: DIFFER  <-- 有分歧，必须查"
  diff "$WD/baseline.log" "$WD/after.log"
fi