# build_sweep.tcl — 频率扫描实验：量化频率对 PnR 收敛/耗时/拥塞的影响
#
# ==================== PC 侧验收清单 ====================
# 目的：验证三条长路径全拆后，引擎能否在 200MHz 真实收敛。
# 这之前手机端已过 9 项 iverilog 回归（sum=31476 稳定、顶层 7 帧帧同步正确）。
# 这是唯一需要 PC 做的一步，做完就签核。
#
# 用法（在装有 Gowin IDE 的 PC 上）：
#   gw_sh build_sweep.tcl 200        # 主验证：200MHz
#   可选对比：gw_sh build_sweep.tcl 50 (_基线) / 400 (_提速)/ 800 (_预期卡死)
#   PLL 源自动选：400→gowin_pll_400.v，其余→gowin_pll_x200.v
#
# 观察三件事：
#   1. 是否收敛？run 走到 report/bitstream = 成功；卡在 ~60% 进度 = 不可达
#   2. 耗时多久？（脚本已打印 elapsed）
#   3. 看 catch 输出的 route congestion：若只有零星热点而非引擎核心区，签核可过
#
# 三种结果 → 对应动作：
#   a) 收敛         → 直接 sign-off；可回头跑 50 对比耗时，验证修复收益
#   b) 收敛但有时序违规(WNS<0) → 贴 WNS/TNS 值回来，我看够不够(可放宽到 180)
#   c) 卡 60%       → 贴卡死时 PnR 日志尾部 + report_route_congestion，定位残留区
# 无论结果如何，把上面三件事的记录贴回对话即可。
# ======================================================
#
# 每个频点一个独立工程目录 OUT/sweep_<freq>m，互不干扰。
# 记录指标：是否完成、耗时、WNS 由 on_finish 打印；拥塞看 PnR 报告。

set DEVICE GW5AST-LV138FPG676AES

# 频率从命令行参数取，缺省 200
if {[llength $argv] > 0} {
    set FREQ_MHZ [lindex $argv 0]
} else {
    set FREQ_MHZ 200
}

# 按目标频率选择引擎 PLL 源文件（VCO 恒 800MHz，改 ODIV0 得输出）
#   200: ODIV0=4 → gowin_pll_x200.v
#   400: ODIV0=2 → gowin_pll_400.v
#   300/500/800 等未提供实体文件 → 兜底用 x200（PnR 时序仍按 -period 约束跑）
switch $FREQ_MHZ {
    400 { set PLL_FILE gowin_pll_400.v }
    default { set PLL_FILE gowin_pll_x200.v }
}

set SRC  F:/sram/sram/rtl/13_mega138k
set PROTO F:/sram/sram/rtl/12_fpga_proto/rtl
set OUT  F:/sram/sram/out/138k_pro/sweep_${FREQ_MHZ}m

set PERIOD_NS [expr {1000.0 / $FREQ_MHZ}]
set HALF_NS   [expr {$PERIOD_NS / 2.0}]

file mkdir $OUT

# ---- 动态生成该频点的 SDC ----
set sdc_content "// frequency sweep: engine clock ${FREQ_MHZ}MHz\n"
append sdc_content "create_clock -name sys_clk -period 20 -waveform {0 10} \[get_ports {sys_clk}\]\n"
append sdc_content "create_clock -name engine_clk -period $PERIOD_NS -waveform {0 $HALF_NS} \[get_nets {clk_200m}\]\n"
append sdc_content "create_clock -name lcd_clk_35 -period 28.571 -waveform {0 14.2855} \[get_nets {lcd_clk_d}\]\n"
append sdc_content "set_clock_group -asynchronous -group \[get_clocks {sys_clk}\] -group \[get_clocks {engine_clk lcd_clk_35}\]\n"

set sdc_file "$OUT/sweep_${FREQ_MHZ}m.sdc"
set fp [open $sdc_file w]
puts $fp $sdc_content
close $fp

puts "=== SWEEP: engine @${FREQ_MHZ}MHz (period ${PERIOD_NS}ns) ==="

# ---- 独立工程 ----
create_project -name board_top_sweep_${FREQ_MHZ} -dir $OUT -pn $DEVICE -device_version B -force
set_device -device_version B $DEVICE

add_file $SRC/board_top.v
add_file $SRC/gowin_pll.v
add_file $SRC/$PLL_FILE
add_file $SRC/lcd_display.v
add_file $SRC/engine_core.v
add_file $PROTO/simd_mac_array.v
add_file $PROTO/reduction_tree.v
add_file $PROTO/reduce_group.v
add_file $SRC/mega138k_engine.cst
add_file $sdc_file

set_option -top_module board_top
set_option -output_base_name board_top
set_option -include_path "$SRC;$PROTO"
set_option -place_option 0
set_option -route_option 0
set_option -global_freq $FREQ_MHZ

set t0 [clock seconds]
run all
set t1 [clock seconds]
set elapsed [expr {$t1 - $t0}]

puts "=== SWEEP RESULT: FREQ=${FREQ_MHZ}MHz PERIOD=${PERIOD_NS}ns 耗时=${elapsed}s ==="
# 覆盖率/拥塞快照（等价于界面报告；命令名随 Gowin 版本可能有差异，失败不阻断结果）
puts "=== route congestion report ==="
catch { report_route_congestion }
puts "=== slot/utilization ==="
catch { report_utilization }
puts "=== SUCCESS: FREQ=${FREQ_MHZ}MHz 达成 ==="
puts "=== 若进程在这里被强制终止 → 该频点不可达（布线死循环）==="
run close