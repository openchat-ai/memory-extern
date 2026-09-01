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
add_file $SRC/lcd_display.v
add_file $SRC/engine_core.v
# ---- 引擎核心（12_fpga_proto 已有 RTL）----
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
# ---- 引脚约束 ----
add_file $SRC/mega138k_engine.cst
# ---- 时序约束：sys_clk 50MHz + PLL 35MHz（解决 PNR 默认 100MHz 约束导致的布线死循环）----
add_file $SRC/mega138k_engine.sdc

set_option -top_module $TOP
set_option -output_base_name board_top
set_option -include_path "$SRC;$PROTO"
set_option -place_option 0
set_option -route_option 0

run all

puts "=== PNR DONE ==="
run close