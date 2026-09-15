# build_periph_smoke_incr.tcl — 增量 PnR（复用上次布局 .p，接口不变时适用）
# 本次：LCD 波形→彩条（顶层接口全不变），WS2812 未动 → 适合增量
# 前置：已有由 build_periph_smoke.tcl 生成的 _r2p3 工程（含 impl/pnr/*.p）
# 用法: gw_sh build_periph_smoke_incr.tcl
# ============================================================================

set TOP board_top_periph_smoke
set OUT  F:/sram/sram/out/138k_pro/periph_smoke
set PROJ "$OUT/${TOP}_r2p3/${TOP}_r2p3.gprj"

# 打开已有工程（绝不 -force 重建，否则 .p 被清）
open_project $PROJ

# CM2030 真实根因（2026-09-03 定位）：工程 process_config.json 里
#   INCREMENTAL_PLACE_AND_ROUTING 与 INCREMENTAL_PLACE_ONLY 两个字段
#   history 持久化残留，会同时为 auto。set_option -inc_pnr 只改前者，
#   不关后者 → 工具读到两个增量标志都 auto → "specified incremental
#   placement and routing" → CM2030 忽略增量退全量。
# 对策：显式 set_option -inc_place 0（清掉 PLACE_ONLY 残留），再开 -inc_pnr auto。
set_option -inc_place 0
set_option -inc_pnr auto

puts "=== PERIPH_SMOKE INCR: open ${PROJ}, inc_pnr=auto (only) ==="

set t0 [clock seconds]
set run_rc [catch { run all } run_err]
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "F:/sram/sram/rtl/13_mega138k/periph_smoke_result.txt"
set fp [open $result_file w]
puts $fp "# periph_smoke INCR PnR 结果（LCD 波形→彩条回退，接口不变）"
puts $fp "mode = INCREMENTAL (inc_place=auto inc_pnr=auto)"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = PNR-DONE"
}
close $fp

puts "=== PERIPH_SMOKE INCR DONE (elapsed ${elapsed}s) ==="
run close
