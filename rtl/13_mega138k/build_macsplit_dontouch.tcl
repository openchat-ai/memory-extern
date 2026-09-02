# build_macsplit_dontouch.tcl — 测试 syn_dont_touch 修复双实例寄存器合并缺陷
# 动机：Gowin Synthesis 对两个完全相同模块实例的 prod_pipe0/kx 寄存器做等价合并
#   导致 hi 实例内部无对应 FF、加法器 I0 读 lo 实例的共享网（跨实例假路径）。
#   本实验给关键流水寄存器加 syn_dont_touch=1 属性，阻止合并。
# 产物落 out/138k_pro/macsplit_dontouch（独立）。
# 用法：gw_sh build_macsplit_dontouch.tcl [route_option] [place_option]
# ============================================================================

set TOP board_top_macsplit_reg
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/macsplit_dontouch

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
add_file $SRC/simd_mac_array_dontouch.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$PROTO"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT

puts "=== MACSPLIT_DONTTOUCH: route_option=${ROUTE_OPT} place_option=${PLACE_OPT} (2x64, syn_dont_touch on pipeline regs) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/macsplit_dontouch_result.txt"
set fp [open $result_file w]
puts $fp "# macsplit_dontouch PnR 结果（syn_dont_touch 修复双实例合并）"
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

puts "=== MACSPLIT_DONTTOUCH DONE (route=${ROUTE_OPT} place=${PLACE_OPT} elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close
