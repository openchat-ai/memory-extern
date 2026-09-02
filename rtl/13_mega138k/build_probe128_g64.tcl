# build_probe.tcl — 200MHz 布线死循环二分探针工程
# 器件：GW5AST-LV138FPG676AES（Ver.B，同 build_sweep）
#
# 用法（PC，Gowin IDE 命令行）：
#   gw_sh build_probe.tcl
#
# 改二分开关只改 board_top_probe.v 的 localparam NUM_LANES：
#   128 → 带引擎全规模；64/32 → 缩 lane；把引擎实例也注释掉 = 纯 PLL 基线
# 输出落 PC 本地 out/138k_pro/probe/；判据由 build_sweep 同法（收敛出 .fs / 卡 60%）
# ============================================================================

set TOP board_top_probe128_g64
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/probe128_g64

file mkdir $OUT

create_project -name board_top_probe128_g64 -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

# ---- 顶层 ----
add_file $SRC/board_top_probe128_g64.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core.v
# ---- 引擎核心（12_fpga_proto）----
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
add_file $PROTO/reduce_group.v

set_option -top_module $TOP
set_option -output_base_name board_top_probe128_g64
set_option -include_path "$SRC;$PROTO"
set_option -place_option 0
set_option -route_option 0

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/probe128_g64_result.txt"
set fp [open $result_file w]
puts $fp "# probe PnR 结果（脚本自动生成，提交即完成回传）"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = PNR-DONE"
}
close $fp

puts "=== PROBE DONE (elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close