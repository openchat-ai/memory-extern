# build_dsplit.tcl — 数据通路级拆分实验（救 128-lane 布线死循环）
# 器件：GW5AST-LV138FPG676AES（Ver.B）
#
# 目的：验证 engine_core_dsplit（acc_bus 按 lane 切成两个独立 64-lane 归约块）
# 能否让 128-lane 的 Routing Phase 1 收敛（A 实验证归约分组无用 → 改数据通路级拆）。
#
# 用法：gw_sh build_dsplit.tcl （PC，Gowin IDE 命令行）
# 判据：收敛出 .rpt.txt / 卡 Routing Phase 1 死循环；由 build_with_deadline.ps1 强制退出
# ============================================================================

set TOP board_top_dsplit
set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/probe_dsplit

file mkdir $OUT

create_project -name board_top_dsplit -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

# ---- 顶层（数据通路级拆分版）----
add_file $SRC/board_top_dsplit.v
add_file $SRC/gowin_pll_x200.v
add_file $SRC/engine_core_dsplit.v
# ---- 引擎核心（12_fpga_proto）----
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
add_file $PROTO/reduce_group.v

set_option -top_module $TOP
set_option -output_base_name board_top_dsplit
set_option -include_path "$SRC;$PROTO"
set_option -place_option 0
set_option -route_option 0

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/dsplit_result.txt"
set fp [open $result_file w]
puts $fp "# data-path-split (2x64) PnR 结果（脚本自动生成）"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = PNR-DONE"
}
close $fp

puts "=== DSPLIT DONE (elapsed ${elapsed}s) ==="
puts "=== 结果已落盘: $result_file ==="
run close