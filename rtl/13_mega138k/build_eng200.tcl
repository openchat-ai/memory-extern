# build_eng200.tcl — 128-lane + 200MHz 单时钟域二分实验
# 器件：GW5AST-LV138FPG676AES（Ver.B）
#
# 用法（PC，Gowin IDE 命令行）：
#   gw_sh build_eng200.tcl              # 默认 place=0 route=0（同 probe 基线）
#   gw_sh build_eng200.tcl 2            # 第一参数 route_option
#   gw_sh build_eng200.tcl 2 3          # route_option=2 place_option=3
#
# 判据由 watch_pnr.ps1 读真实信号：进程存活/CPU 增量/产物文件，
# 绝不靠 log 行数猜测。结果落 rtl/13_mega138k/eng200_result.txt。
# ============================================================================

set TOP board_top_eng200
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/eng200

set ROUTE_OPT 0
set PLACE_OPT 0
if {[llength $argv] > 0} { set ROUTE_OPT [lindex $argv 0] }
if {[llength $argv] > 1} { set PLACE_OPT [lindex $argv 1] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

add_file $SRC/${TOP}.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core.v
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
add_file $PROTO/reduce_group.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT

puts "=== ENG200: route_option=${ROUTE_OPT} place_option=${PLACE_OPT} (128-lane single-200MHz) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/eng200_result.txt"
set fp [open $result_file w]
puts $fp "# eng200 PnR 结果（脚本自动生成）"
puts $fp "route_option = ${ROUTE_OPT}"
puts $fp "place_option = ${PLACE_OPT}"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = PNR-DONE"
}
close $fp

puts "=== ENG200 DONE (route=${ROUTE_OPT} place=${PLACE_OPT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close