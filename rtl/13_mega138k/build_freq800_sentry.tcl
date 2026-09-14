# build_freq800_sentry.tcl — 800 哨兵 PnR（PLL-X800 实体 + 纯 fabric 计数哨兵）
# 用途：docs/PC-BURN-EXECUTION.md 烧录清单 #2。判定 800 可行性 = PLL 能否
#      产出 800MHz(+lock) 且 fabric 1.25ns 走线可收敛。
# 参数沿用已收敛 macsplit 引擎(route=2/place=3/max_fanout=100/opt_goal=timing)。
# 产物: out/138k_pro/freq800_sentry
# 用法: gw_sh build_freq800_sentry.tcl [route_option] [place_option] [max_fanout]
# ============================================================================

set TOP board_freq800_sentry
set SRC  F:/sram/sram/rtl/13_mega138k
set OUT  F:/sram/sram/out/138k_pro/freq800_sentry

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
add_file $SRC/freq800_sentry_top.v
add_file $SRC/gowin_pll_x800.v
add_file $SRC/freq800_sentry.sdc
add_file $SRC/freq800_sentry.cst

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT
set_option -max_fanout $MAX_FANOUT
set_option -opt_goal timing

puts "=== FREQ800_SENTRY: route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} (PLL-X800 + 800 域哨兵) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/freq800_sentry_result.txt"
set fp [open $result_file w]
puts $fp "# freq800_sentry PnR 结果（800 哨兵，PLL-X800 + fabric 1.25ns 收敛判定）"
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

puts "=== FREQ800_SENTRY DONE (route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close