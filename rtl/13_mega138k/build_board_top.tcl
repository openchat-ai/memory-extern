# build_board_top.tcl — Tang Mega 138K Pro 综合脚本
# 器件：GW5AST-138B, part number GW5AST-LV138FPG676AES（官方 led demo 同款）

set TOP board_top
set SRC F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT F:/sram/sram/out/138k_pro/synth

file mkdir $OUT

create_project -name board_top -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

# ---- 顶层设计文件 ----
add_file $SRC/board_top.v
add_file $SRC/gowin_pll.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/lcd_display.v
add_file $SRC/engine_core.v
# ---- 引擎核心（12_fpga_proto 已有 RTL）----
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
add_file $PROTO/reduce_group.v
# ---- 引脚约束 ----
add_file $SRC/mega138k_engine.cst
# ---- 时序约束：引擎 200MHz + PLL 35MHz（PIPE_MUL=1 打断关键路径后可达）----
add_file $SRC/mega138k_engine.sdc

set_option -top_module $TOP
set_option -output_base_name board_top
set_option -include_path "$SRC;$PROTO"
set_option -place_option 0
set_option -route_option 0

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/board_top_result.txt"
set fp [open $result_file w]
puts $fp "# board_top PnR 结果（脚本自动生成，提交即完成回传）"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = PNR-DONE"
}
close $fp

puts "=== PNR DONE (elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close