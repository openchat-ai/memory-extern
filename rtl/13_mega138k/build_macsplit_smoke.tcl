# build_macsplit_smoke.tcl — 冒烟用收敛位流（dontouch 修复网表 + 正确 CST 引脚 + 布局收敛干预）
# 目的（用户：不想反复重布，编译成功想烧 FPGA 体验）：
#   1. 修复版网表(engine_core_macsplit_reg + simd_mac_array_dontouch) + 正确引脚 CST（P16/J14...）
#      —— 上一版 macsplit_dontouch 无 CST，自动引脚，烧上去 LED 不亮。这版必须引脚正确。
#   2. 时序干预提 Fmax：opt_goal=timing + max_fanout 压低(x/wt 广播竞争) + place3/route2
#      —— 目标从 91MHz 尽量上探一档(110~130 区间)，至少保证 LED 心跳(独立计数器)烧上即亮。
# 产物: out/138k_pro/macsplit_smoke（独立，不碰其他工作流）。
# 用法: gw_sh build_macsplit_smoke.tcl [route_option] [place_option] [max_fanout]
# ============================================================================

set TOP board_top_macsplit_reg
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/macsplit_smoke

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
add_file $SRC/macsplit_timing.sdc
add_file $SRC/macsplit_engine.cst
add_file $SRC/reduction_tree_reg.v
add_file $SRC/reduce_group_reg.v
add_file $SRC/simd_mac_array_dontouch.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT
set_option -max_fanout $MAX_FANOUT
set_option -opt_goal timing

puts "=== MACSPLIT_SMOKE: route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} (dontouch netlist + CST + timing) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/macsplit_smoke_result.txt"
set fp [open $result_file w]
puts $fp "# macsplit_smoke PnR 结果（dontouch netlist + 正确 CST + 时序干预）"
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

puts "=== MACSPLIT_SMOKE DONE (route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close
