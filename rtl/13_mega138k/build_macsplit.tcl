# build_macsplit.tcl — MAC 阵列级拆分实验（128-lane 拆两个独立 64 收敛块）
# 器件：GW5AST-LV138FPG676AES（Ver.B）
#
# 用法（PC，Gowin IDE 命令行）：
#   gw_sh build_macsplit.tcl              # 默认 place=0 route=2
#   gw_sh build_macsplit.tcl 0            # 第一参数 route_option
#   gw_sh build_macsplit.tcl 0 3          # route_option=0 place_option=3
#
# 判据由 watch_pnr.ps1 读真实信号：进程存活/CPU 增量/产物文件，
# 绝不靠 log 行数猜测。结果落 rtl/13_mega138k/macsplit_result.txt。
# ============================================================================

set TOP board_top_macsplit
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/macsplit

set ROUTE_OPT 2
set PLACE_OPT 0
if {[llength $argv] > 0} { set ROUTE_OPT [lindex $argv 0] }
if {[llength $argv] > 1} { set PLACE_OPT [lindex $argv 1] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

add_file $SRC/${TOP}.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core_macsplit.v
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
add_file $PROTO/reduce_group.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT

puts "=== MACSPLIT: route_option=${ROUTE_OPT} place_option=${PLACE_OPT} (2x64-lane independent blocks) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/macsplit_result.txt"
set fp [open $result_file w]
puts $fp "# macsplit PnR 结果（脚本自动生成）"
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

puts "=== MACSPLIT DONE (route=${ROUTE_OPT} place=${PLACE_OPT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close