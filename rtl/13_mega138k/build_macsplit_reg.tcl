# build_macsplit_reg.tcl — stage 强制 FF 实现（syn_ramstyle=registers）时序实验
# 动机：reduce_group 的 stage 二维数组被综合器推断成 RAM，物理打包集中，
#   迫使 2048bit acc 总线跨区域布线（布线慢/时序差的根源之一）。
#   本版用 syn_ramstyle="registers" 强制 stage 用 FF 实现，加法器+寄存器就近。
# 产物落 out/138k_pro/macsplit_reg（独立）。
# 用法：gw_sh build_macsplit_reg.tcl [route_option] [place_option]
# ============================================================================

set TOP board_top_macsplit_reg
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/macsplit_reg

set ROUTE_OPT 2
set PLACE_OPT 0
if {[llength $argv] > 0} { set ROUTE_OPT [lindex $argv 0] }
if {[llength $argv] > 1} { set PLACE_OPT [lindex $argv 1] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

add_file $SRC/${TOP}.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core_macsplit_reg.v
add_file $SRC/macsplit_timing.sdc
add_file $SRC/reduction_tree_reg.v
add_file $SRC/reduce_group_reg.v
add_file $PROTO/simd_mac_array.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT

puts "=== MACSPLIT_REG: route_option=${ROUTE_OPT} place_option=${PLACE_OPT} (2x64, stage=FF) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/macsplit_reg_result.txt"
set fp [open $result_file w]
puts $fp "# macsplit_reg PnR 结果（脚本自动生成）"
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

puts "=== MACSPLIT_REG DONE (route=${ROUTE_OPT} place=${PLACE_OPT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close