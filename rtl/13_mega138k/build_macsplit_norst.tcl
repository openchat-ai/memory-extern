# build_macsplit_norst.tcl — 去复位归约树版纯引擎时序实验（200MHz）
# 动机：full_macsplit/macsplit_timing 的 RESET/rst_sync 关键路径说明
#   rst 被综合进数据路径。本版用 reduction_tree_norst（stage 数据寄存器无复位）。
# 产物落 out/138k_pro/macsplit_norst（独立）。
# 用法：gw_sh build_macsplit_norst.tcl [route_option] [place_option]
# ============================================================================

set TOP board_top_macsplit_norst
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/macsplit_norst

set ROUTE_OPT 2
set PLACE_OPT 0
if {[llength $argv] > 0} { set ROUTE_OPT [lindex $argv 0] }
if {[llength $argv] > 1} { set PLACE_OPT [lindex $argv 1] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

add_file $SRC/${TOP}.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core_macsplit_norst.v
add_file $SRC/macsplit_timing.sdc
add_file $SRC/reduction_tree_norst.v
add_file $SRC/reduce_group_norst.v
add_file $PROTO/simd_mac_array.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT

puts "=== MACSPLIT_NORST: route_option=${ROUTE_OPT} place_option=${PLACE_OPT} (2x64, no-rst reduction tree) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/macsplit_norst_result.txt"
set fp [open $result_file w]
puts $fp "# macsplit_norst PnR 结果（脚本自动生成）"
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

puts "=== MACSPLIT_NORST DONE (route=${ROUTE_OPT} place=${PLACE_OPT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close