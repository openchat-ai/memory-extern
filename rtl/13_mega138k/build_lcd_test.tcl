# build_lcd_test.tcl — 独立 LCD 小位流 (调显示迭代用: 1~2 分钟一轮, 而整包 16 分钟)
# 用法: gw_sh build_lcd_test.tcl
# 规模: PLL + lcd_display + 计数器/LFSR ≈ 几千 LUT (整包 decode_top 是 25K)
# 前提: 改显示相关代码后先烧这个验证, 确认无误再并回整包 (build_decode_top.tcl)
# ============================================================================

set TOP board_lcd_test
set SRC F:/sram/sram/rtl/13_mega138k
set OUT F:/sram/sram/out/138k_pro/lcd_test

file mkdir $OUT
create_project -name ${TOP} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

add_file $SRC/${TOP}.v
add_file $SRC/lcd_display.v
add_file $SRC/gowin_pll.v
add_file $SRC/mega138k_lcd_test.sdc
add_file $SRC/mega138k_lcd_test.cst

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC"
set_option -place_option 3
set_option -route_option 2
set_option -max_fanout 100
set_option -opt_goal timing

puts "=== LCD_TEST: ${TOP} (files: top + lcd_display + gowin_pll + sdc + cst) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set rf "$OUT/lcd_test_result.txt"
set fp [open $rf w]
puts $fp "# board_lcd_test result"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = DONE"
}
close $fp

puts "=== LCD_TEST DONE (elapsed ${elapsed}s) ==="
puts "=== result: $rf ==="
run close
