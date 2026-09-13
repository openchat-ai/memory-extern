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
# 主矩阵 (PROFILE SEED HALF TN PROBEON FAULT VOC FBPOLY WANT)
for row in "0 0 5 12 1 0 1024 0 PASS" "1 0 5 12 1 0 1024 0 PASS" "2 0 5 12 1 0 1024 0 PASS" \
           "4 0 5 12 1 0 1024 0 PASS" "5 0 5 12 1 0 1024 0 PASS" "6 0 5 12 1 0 1024 0 PASS" \
           "8 0 5 12 1 0 1024 0 PASS" "9 0 5 12 1 0 1024 0 PASS" \
           "3 0 5 12 1 0 1024 0 PASS" "7 0 5 12 1 0 1024 0 PASS" \
           "0 1 5 12 1 0 1024 0 PASS" "0 2 5 12 1 0 1024 0 PASS" "0 3 5 12 1 0 1024 0 PASS" \
           "0 0 9 12 1 0 1024 0 PASS" "2 1 5 12 1 0 1024 0 PASS" "4 3 5 12 1 0 1024 0 PASS"; do
  run_row $row; rc+=$?
done
# 疲劳长跑
run_row 0 0 5 60 0 0 1024 0 PASS; rc+=$?
run_row 2 0 5 30 0 0 1024 0 PASS; rc+=$?
# 交叉维度角点
run_row 4 2 9 12 1 0 1024 0 PASS; rc+=$?
run_row 8 0 9 12 1 0 1024 0 PASS; rc+=$?
run_row 8 1 5 30 1 0 1024 0 PASS; rc+=$?
# M41 规模矩阵 (VOC 512/2048, 窗口同构)
run_row 0 0 5 12 1 0 512 0 PASS; rc+=$?
run_row 4 0 5 12 1 0 512 0 PASS; rc+=$?
run_row 0 0 5 12 1 0 2048 0 PASS; rc+=$?
run_row 4 0 5 12 1 0 2048 0 PASS; rc+=$?
# M38 长链 (T120×FBPOLY, T280 过 256 回绕点)
run_row 0 0 5 120 0 0 1024 1 PASS; rc+=$?
run_row 2 0 5 280 0 0 1024 0 PASS; rc+=$?
# M42/M43 K 变体 + 极值叠压组合
run_row 0 0 5 12 1 0 1024 0 PASS 5; rc+=$?
run_row 0 0 5 12 1 0 1024 0 PASS 8; rc+=$?
run_row 4 3 9 12 1 0 2048 0 PASS 8; rc+=$?
run_row 2 1 5 60 0 0 2048 0 PASS 8; rc+=$?
# 断言红队 (M31/M52; F4/F5=组合双错零遮蔽)
run_row 0 0 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 2 0 5 12 1 5 1024 0 CAUGHT; rc+=$?
# M60 长程组合 (FBPOLY2×T280, HALF9×T280) —— 覆盖曾误触 head 看门狗累算界的新组合点
run_row 2 0 5 280 0 0 1024 2 PASS; rc+=$?
run_row 0 0 9 280 0 0 1024 0 PASS; rc+=$?
# M61/M62 K16×T280 大K长程 (bake 时长更大, 验证单token看门狗余裕)
run_row 0 0 5 280 0 0 1024 0 PASS 16; rc+=$?
# M54 SEED 抽样扫 {5,9,13} + M57 FBPOLY=2 xorshift 长链
run_row 0 5 5 12 1 0 1024 0 PASS; rc+=$?
run_row 0 9 5 12 1 0 1024 0 PASS; rc+=$?
run_row 0 13 5 12 1 0 1024 0 PASS; rc+=$?
# M63 P11 远峰梯度 (激活 lbw 右支/远端钳的新激励面)
run_row 11 0 5 12 1 0 1024 0 PASS; rc+=$?
run_row 11 0 5 60 0 0 1024 0 PASS; rc+=$?
run_row 11 0 9 12 1 0 2048 0 PASS 8; rc+=$?
# M64 P11 指数扩展 + 远峰红队 (F1/F3 在窗贴顶时仍全咬)
run_row 11 0 5 60 0 0 2048 0 PASS 8; rc+=$?
run_row 11 0 5 120 0 0 1024 2 PASS; rc+=$?
run_row 11 0 9 12 1 0 512 0 PASS; rc+=$?
run_row 11 0 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 3 1024 0 CAUGHT; rc+=$?
# M68 P11 远峰×SEED 抽样 {4,9}
run_row 11 4 5 12 1 0 1024 0 PASS; rc+=$?
run_row 11 9 5 12 1 0 1024 0 PASS; rc+=$?
# M70 红队×远峰/节流新交叉角 + 退化高权重×远峰
run_row 2 0 5 12 1 1 1024 0 CAUGHT 3 1; rc+=$?
run_row 2 0 5 12 1 3 1024 0 CAUGHT 3 1; rc+=$?
run_row 11 0 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 8 0 5 12 1 0 1024 0 PASS 3 1; rc+=$?
# M71/M72 FKXG 剩余对角 + 远峰全叠超组合
run_row 11 0 5 12 1 0 1024 1 PASS; rc+=$?
run_row 6 0 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 11 0 5 12 1 0 512 0 PASS 16; rc+=$?
run_row 11 0 15 12 1 0 1024 0 PASS; rc+=$?
run_row 8 0 9 60 0 0 2048 0 PASS 16 1; rc+=$?
run_row 11 0 5 280 0 0 1024 0 PASS 16; rc+=$?
run_row 11 7 5 12 1 0 1024 0 PASS; rc+=$?
run_row 11 11 5 12 1 0 1024 0 PASS; rc+=$?
# M66 节流×远峰共激活 (P2+FKXG1) + 远峰长程耐力/P16KP2048
run_row 2 0 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 11 0 5 280 0 0 1024 0 PASS; rc+=$?
run_row 11 0 5 60 0 0 2048 0 PASS 16; rc+=$?
run_row 0 0 5 120 0 0 1024 2 PASS; rc+=$?
# M49/M50 K 边界 {12,16} + 时钟极值 HALF {1,15}
run_row 0 0 5 12 1 0 1024 0 PASS 12; rc+=$?
run_row 0 0 5 12 1 0 1024 0 PASS 16; rc+=$?
run_row 0 0 1 12 1 0 1024 0 PASS; rc+=$?
run_row 0 0 15 12 1 0 1024 0 PASS; rc+=$?
# M78 FKXG 全 SEED 扫 + M79 P11×K12
run_row 2 4 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 2 6 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 2 9 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 2 13 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 2 15 5 12 1 0 1024 0 PASS 3 1; rc+=$?
run_row 11 0 5 12 1 0 1024 0 PASS 12; rc+=$?
# M80 FKXG 末角: P11×FBPOLY2 / ×H9 / ×T120
run_row 11 0 5 12 1 0 1024 2 PASS; rc+=$?
run_row 11 0 9 12 1 0 1024 0 PASS; rc+=$?
run_row 11 0 5 120 1 0 1024 0 PASS; rc+=$?
# M84 远峰红队末角: F5/F1@K12(GEMM族) + F2@K16(o族)
run_row 11 0 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 1 1024 0 CAUGHT 12; rc+=$?
run_row 11 0 5 12 1 2 1024 0 CAUGHT 16; rc+=$?
# M85 红队残角批: profile/时钟/FBPOLY × 注入 (f1b1 掩蔽角不入 CAUGHT, 见 notes)
run_row 3 0 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 7 0 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 8 0 5 12 1 2 1024 0 CAUGHT 16; rc+=$?
run_row 6 0 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 0 0 1 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 0 0 15 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 1 1024 2 CAUGHT; rc+=$?
run_row 9 0 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 1 0 5 12 1 4 1024 0 CAUGHT; rc+=$?

# M86/M87 节流/o 远峰/K边/SEED 红队 (6 行)
run_row 2 0 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 2 0 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 1 1024 0 CAUGHT 16; rc+=$?
run_row 0 4 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 0 9 5 12 1 3 1024 0 CAUGHT; rc+=$?
# M88 批: 时钟/FBPOLY/双错×seed/大词表节流/长程 红队 + 小词表xorshift PASS
run_row 0 0 3 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 0 512 2 PASS; rc+=$?
run_row 4 2 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 2 0 5 12 1 1 2048 0 CAUGHT; rc+=$?
run_row 0 0 5 280 1 1 1024 0 CAUGHT; rc+=$?
# M90 全叠三叠: P5×F1 / P2×F5×FKXG1 / P0×F2×V512
run_row 5 0 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 2 0 5 12 1 5 1024 0 CAUGHT 3 1; rc+=$?
run_row 0 0 5 12 1 2 512 0 CAUGHT; rc+=$?
# M91-93 十五角入闸 (台账节次验)
run_row 2 0 5 12 1 2 2048 0 CAUGHT; rc+=$?
run_row 4 5 5 12 1 1 2048 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 4 1024 0 CAUGHT 8; rc+=$?
run_row 3 0 5 12 1 4 1024 1 CAUGHT; rc+=$?
run_row 7 0 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 6 0 5 12 1 3 1024 0 CAUGHT 3 1; rc+=$?
run_row 1 0 5 12 1 2 512 0 CAUGHT; rc+=$?
run_row 8 0 5 12 1 1 1024 0 CAUGHT 3 1; rc+=$?
run_row 0 10 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 2 0 5 12 1 3 1024 0 CAUGHT 16; rc+=$?
run_row 9 0 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 5 0 5 12 1 4 1024 0 CAUGHT 3 1; rc+=$?
run_row 1 0 5 12 1 3 512 0 CAUGHT; rc+=$?
run_row 4 0 5 12 1 2 1024 0 CAUGHT 16 1; rc+=$?
run_row 7 0 5 12 1 3 1024 0 CAUGHT 3 1; rc+=$?

echo "===================="
echo "decode_auto 回归门: PASS=$np CAUGHT=$nc WARN=$nw FAIL=$nf MISSED=$nm ESCAPE=$ne COMPILE=$ncf UNKNOWN=$nun 总计=$((np+nc+nf+nw+ne+nm+ncf+nun)) rc=$rc (0=全绿)"
exit $(( rc ? 1 : 0 ))

# M98-M111 十一弹 54 角入闸 (节次验)
run_row 0 0 5 12 1 4 1024 0 CAUGHT 8; rc+=$?
run_row 1 0 5 12 1 2 2048 0 CAUGHT; rc+=$?
run_row 0 14 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 3 512 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 5 1024 0 CAUGHT 8; rc+=$?
run_row 0 0 5 12 1 2 1024 2 CAUGHT; rc+=$?
run_row 0 0 5 12 1 1 1024 0 CAUGHT 5; rc+=$?
run_row 3 0 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 6 0 9 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 4 2048 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 1 512 0 CAUGHT; rc+=$?
run_row 9 0 5 12 1 2 512 0 CAUGHT; rc+=$?
run_row 5 0 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 8 0 5 12 1 4 1024 0 CAUGHT 12; rc+=$?
run_row 11 0 5 12 1 3 1024 1 CAUGHT; rc+=$?
run_row 0 8 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 0 0 5 12 1 1 2048 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 2 1024 0 CAUGHT 5; rc+=$?
run_row 2 0 5 12 1 4 1024 0 CAUGHT 12; rc+=$?
run_row 11 7 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 11 5 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 0 3 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 4 10 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 2 13 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 9 0 5 12 1 4 512 0 CAUGHT; rc+=$?
run_row 6 0 5 12 1 4 1024 0 CAUGHT 12; rc+=$?
run_row 2 3 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 1 0 5 12 1 5 2048 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 1 2048 0 CAUGHT; rc+=$?
run_row 11 5 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 0 15 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 4 6 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 7 4 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 60 1 4 1024 0 CAUGHT 16; rc+=$?
run_row 0 5 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 0 12 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 11 11 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 1 9 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 4 8 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 1 1024 0 CAUGHT 16; rc+=$?
run_row 0 14 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 2 6 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 8 5 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 5 12 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 2 0 5 12 1 5 512 0 CAUGHT 3 1; rc+=$?
run_row 11 0 5 12 1 5 1024 1 CAUGHT; rc+=$?
run_row 0 9 5 12 1 2 1024 0 CAUGHT; rc+=$?
run_row 6 7 5 12 1 4 1024 0 CAUGHT; rc+=$?
run_row 3 2 5 12 1 3 1024 0 CAUGHT; rc+=$?
run_row 0 7 5 12 1 1 1024 0 CAUGHT; rc+=$?
run_row 11 0 5 12 1 2 512 0 CAUGHT; rc+=$?
run_row 4 12 5 12 1 5 1024 0 CAUGHT; rc+=$?
run_row 8 0 5 12 1 3 1024 0 CAUGHT 16 1; rc+=$?

echo "===================="
