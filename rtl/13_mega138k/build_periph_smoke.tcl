# build_periph_smoke.tcl — 全外设冒烟（引擎 + WS2812 + 按键 + RGB LCD）
# 用途：一次性把板载外设全部点亮验证。复用已收敛的 macsplit 引擎 124.3MHz 参数
#       (route=2/place=3/max_fanout=100/opt_goal=timing)。
# 产物: out/138k_pro/periph_smoke（独立，不碰其他工作流）
# 用法: gw_sh build_periph_smoke.tcl [route_option] [place_option] [max_fanout]
# ============================================================================

set TOP board_top_periph_smoke
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/periph_smoke

set ROUTE_OPT 2
set PLACE_OPT 3
set MAX_FANOUT 100
if {[llength $argv] > 0} { set ROUTE_OPT [lindex $argv 0] }
if {[llength $argv] > 1} { set PLACE_OPT [lindex $argv 1] }
if {[llength $argv] > 2} { set MAX_FANOUT [lindex $argv 2] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

add_file $SRC/${TOP}.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core_macsplit_reg.v
add_file $SRC/reduction_tree_reg.v
add_file $SRC/reduce_group_reg.v
add_file $SRC/simd_mac_array_dontouch.v
add_file $SRC/ws2812_smoke.v
add_file $SRC/periph_smoke.sdc
add_file $SRC/periph_smoke.cst

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT
set_option -max_fanout $MAX_FANOUT
set_option -opt_goal timing

puts "=== PERIPH_SMOKE: route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} (engine+ws2812+key+lcd) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/periph_smoke_result.txt"
set fp [open $result_file w]
puts $fp "# periph_smoke PnR 结果（engine + WS2812 + 按键 + RGB LCD 全外设冒烟）"
puts $fp "route_option = ${ROUTE_OPT}"
puts $fp "place_option = ${PLACE_OPT}"
puts $fp "max_fanout = ${MAX_FANOUT}"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = PNR-DONE"
}
close $fp

puts "=== PERIPH_SMOKE DONE (route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close
