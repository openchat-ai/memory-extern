# build_decode_top.tcl 鈥?board_decode_top 鏁村寘锛坉ecode 闂幆涓荤嚎涓婄锛?# 鐢ㄩ€旓紙PC-BURN-M25.md 鎵挎帴浠讹紝姝ゅ墠浠庢湭鍦?PC 涓?PnR/鐑у綍杩囷級:
#   14 浠芥枃浠?= 1 椤跺眰 + 1 core + 6 涓?*_sf 闀滃儚 + 6 涓骇鍝佷欢锛堥浂鏀瑰姩锛?#   鍒ゅ喅 led[3]=GOOD 鍙岃瘉锛坆oard_decode_top.v:62锛?#     姣忓抚 a_words 澧為噺鎭?=128锛堝叏閲忥級 涓?甯у唴 hsh_nz锛堝唴瀹规祦娲昏穬锛?#     杩炵画 2 甯?鈫?good[1]=1 鈫?led[3]=0 鈫?M25 鐐逛寒锛堝叡闃虫瀬浣庝寒锛?#
# 閰嶇疆娌跨敤 macsplit_smoke 鐨勮儨鍑虹粍鍚堬紙route=2 / place=3 / max_fanout=100 /
# opt_goal=timing锛夛紝瑙?macsplit_smoke_result.txt锛團max 124.311MHz锛夈€?#
# 鐢ㄦ硶:
#   gw_sh build_decode_top.tcl                 # 鍏ㄩ噺 synth+pnr
#   gw_sh build_decode_top.tcl synth           # 鍙患鍚堬紝鎷胯祫婧愯处锛堜究瀹滐紝~1-5min锛?#   gw_sh build_decode_top.tcl synth 2 3 100   # 鏄惧紡浼?route/place/fanout
# ============================================================================

set TOP board_decode_top
set SRC  F:/sram/sram/rtl/13_mega138k
set R    F:/sram/sram/rtl
set OUT  F:/sram/sram/out/138k_pro/decode_top

set MODE    all
set ROUTE_OPT    2
set PLACE_OPT    3
set MAX_FANOUT   100
if {[llength $argv] > 0} { set MODE [lindex $argv 0] }
if {[llength $argv] > 1} { set ROUTE_OPT [lindex $argv 1] }
if {[llength $argv] > 2} { set PLACE_OPT [lindex $argv 2] }
if {[llength $argv] > 3} { set MAX_FANOUT [lindex $argv 3] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

# --- 1 椤跺眰 + core + 绾︽潫 ---
add_file $SRC/${TOP}.v
add_file $SRC/decode_auto_core.v
add_file $SRC/uart_tx.v
add_file $SRC/uart_rx.v
add_file $SRC/lcd_display.v
add_file $SRC/gowin_pll.v
add_file $SRC/mega138k_decode.sdc
add_file $SRC/mega138k_decode.cst

# --- 2 鍏釜 *_sf 闀滃儚锛坹s0.68 鏁扮粍/鍙傛暟 for 鐣屽吋瀹圭増锛屼骇鍝佷欢涓嶅姩锛?--
add_file $SRC/route_asm_sf.v
add_file $SRC/router_sel_sf.v
add_file $SRC/attn_inner_ctl_sf.v
add_file $SRC/head_vprune_sf.v
add_file $SRC/vocab_prune_sf.v
add_file $SRC/output_head_sf.v

# --- 3 鍏釜浜у搧浠讹紙闆舵敼鍔級---
add_file $R/26_sched_exec/sched_exec.v
add_file $R/19_gemv_rail/gemv_rail_ctl.v
add_file $R/18_sram_pool_arb/sram_pool_arb.v
add_file $R/20_attn_window/attn_window.v
add_file $R/05_gemv/gemv_array_128.v
add_file $R/34_assembler/assembler.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$R/05_gemv;$R/16_reduction"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT
set_option -max_fanout $MAX_FANOUT
set_option -opt_goal timing

puts "=== DECODE_TOP: mode=${MODE} route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} ==="
puts "=== files: 1 top + 1 core + 6 sf + 6 product + uart_tx + uart_rx + lcd_display + gowin_pll = 18 ==="

set t0 [clock seconds]
if {$MODE eq "synth"} {
    set run_rc [catch { run syn } run_err]
} else {
    set run_rc [catch { run all } run_err]
}
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/decode_top_result.txt"
set fp [open $result_file w]
# 缁撴灉鏂囦欢涓€寰?ASCII: Gowin 鐨?tcl 瑙ｉ噴鍣ㄦ寜绯荤粺缂栫爜(GBK)璇绘簮鏂囦欢, 鍐欏嚭鐨勪腑鏂?# 鏄贩鍚堝瓧鑺?(鍚屼竴琛岄噷鏈夌殑瀛楀鏈夌殑瀛楀潖)銆備腑鏂囧彊杩版斁 decode_top_result.md
# (鎵嬪啓, UTF-8), 杩欓噷鐨勬満鍣ㄨ瀛楁淇濇寔绾?ASCII銆?puts $fp "# board_decode_top PnR result (14 files)"
puts $fp "# NOTE: machine-readable section only (ASCII). Chinese narrative:"
puts $fp "#       see rtl/13_mega138k/decode_top_result.md (hand-written, UTF-8)"
puts $fp "mode = ${MODE}"
puts $fp "route_option = ${ROUTE_OPT}"
puts $fp "place_option = ${PLACE_OPT}"
puts $fp "max_fanout = ${MAX_FANOUT}"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = DONE"
}
close $fp

puts "=== DECODE_TOP DONE (mode=${MODE} elapsed ${elapsed}s) ==="
puts "=== result file: $result_file ==="
run close