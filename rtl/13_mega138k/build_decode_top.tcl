# build_decode_top.tcl — board_decode_top 整包（decode 闭环主线上硅）
# 用途（PC-BURN-M25.md 承接件，此前从未在 PC 上 PnR/烧录过）:
#   14 份文件 = 1 顶层 + 1 core + 6 个 *_sf 镜像 + 6 个产品件（零改动）
#   判决 led[3]=GOOD 双证（board_decode_top.v:62）
#     每帧 a_words 增量恒 =128（全量） 且 帧内 hsh_nz（内容流活跃）
#     连续 2 帧 → good[1]=1 → led[3]=0 → M25 点亮（共阳极低亮）
#
# 配置沿用 macsplit_smoke 的胜出组合（route=2 / place=3 / max_fanout=100 /
# opt_goal=timing），见 macsplit_smoke_result.txt（Fmax 124.311MHz）。
#
# 用法:
#   gw_sh build_decode_top.tcl                 # 全量 synth+pnr
#   gw_sh build_decode_top.tcl synth           # 只综合，拿资源账（便宜，~1-5min）
#   gw_sh build_decode_top.tcl synth 2 3 100   # 显式传 route/place/fanout
# ============================================================================

set TOP board_decode_top
set SRC  F:/sram/sram/rtl/13_mega138k
set R    F:/sram/sram/rtl
set OUT  F:/sram/sram/out/138k_pro/decode_top

set MODE    all
set ROUTE_OPT    2
set PLACE_OPT    3
set MAX_FANOUT   100
if {[llength $argv] > 0} { set MODE [lindex $argv 0] }
if {[llength $argv] > 1} { set ROUTE_OPT [lindex $argv 1] }
if {[llength $argv] > 2} { set PLACE_OPT [lindex $argv 2] }
if {[llength $argv] > 3} { set MAX_FANOUT [lindex $argv 3] }

file mkdir $OUT

create_project -name ${TOP}_r${ROUTE_OPT}p${PLACE_OPT} -dir $OUT -pn GW5AST-LV138FPG676AES -device_version B -force
set_device -device_version B GW5AST-LV138FPG676AES

# --- 1 顶层 + core + 约束 ---
add_file $SRC/${TOP}.v
add_file $SRC/decode_auto_core.v
add_file $SRC/mega138k_decode.sdc
add_file $SRC/mega138k_decode.cst

# --- 2 六个 *_sf 镜像（ys0.68 数组/参数 for 界兼容版，产品件不动）---
add_file $SRC/route_asm_sf.v
add_file $SRC/router_sel_sf.v
add_file $SRC/attn_inner_ctl_sf.v
add_file $SRC/head_vprune_sf.v
add_file $SRC/vocab_prune_sf.v
add_file $SRC/output_head_sf.v

# --- 3 六个产品件（零改动）---
add_file $R/26_sched_exec/sched_exec.v
add_file $R/19_gemv_rail/gemv_rail_ctl.v
add_file $R/18_sram_pool_arb/sram_pool_arb.v
add_file $R/20_attn_window/attn_window.v
add_file $R/05_gemv/gemv_array_128.v
add_file $R/34_assembler/assembler.v

set_option -top_module $TOP
set_option -output_base_name ${TOP}
set_option -include_path "$SRC;$R/05_gemv;$R/16_reduction"
set_option -place_option $PLACE_OPT
set_option -route_option $ROUTE_OPT
set_option -max_fanout $MAX_FANOUT
set_option -opt_goal timing

puts "=== DECODE_TOP: mode=${MODE} route=${ROUTE_OPT} place=${PLACE_OPT} max_fanout=${MAX_FANOUT} ==="
puts "=== files: 1 top + 1 core + 6 sf + 6 product = 14 ==="

set t0 [clock seconds]
if {$MODE eq "synth"} {
    set run_rc [catch { run syn } run_err]
} else {
    set run_rc [catch { run all } run_err]
}
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

set result_file "$SRC/decode_top_result.txt"
set fp [open $result_file w]
# 结果文件一律 ASCII: Gowin 的 tcl 解释器按系统编码(GBK)读源文件, 写出的中文
# 是混合字节 (同一行里有的字对有的字坏)。中文叙述放 decode_top_result.md
# (手写, UTF-8), 这里的机器读字段保持纯 ASCII。
puts $fp "# board_decode_top PnR result (14 files)"
puts $fp "# NOTE: machine-readable section only (ASCII). Chinese narrative:"
puts $fp "#       see rtl/13_mega138k/decode_top_result.md (hand-written, UTF-8)"
puts $fp "mode = ${MODE}"
puts $fp "route_option = ${ROUTE_OPTION}"
puts $fp "place_option = ${PLACE_OPTION}"
puts $fp "max_fanout = ${MAX_FANOUT}"
puts $fp "elapsed_s = ${elapsed}"
if {$run_rc} {
    puts $fp "status = FAIL-EXCEPTION"
    puts $fp "detail = $run_err"
} else {
    puts $fp "status = DONE"
}
close $fp

puts "=== DECODE_TOP DONE (mode=${MODE} elapsed ${elapsed}s) ==="
puts "=== result file: $result_file ==="
run close