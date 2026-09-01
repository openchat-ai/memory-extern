# mk_diag.tcl — 把 OUT 目录里的 PnR 大日志整理成一份 <10KB 诊断文本（入仓用）
#
# 用法（在装有 Gowin IDE 的 PC 上，于仓库内运行）：
#   gw_sh mk_diag.tcl F:/sram/sram/out/138k_pro/sweep_200m
#   gw_sh mk_diag.tcl F:/sram/sram/out/138k_pro/synth
#
# 输出：仓库内 rtl/13_mega138k/diag_<tag>.txt
#   status      = PNR-DONE / PR-FAIL / SEED-FAIL
#   关键判据    = 收敛 / 卡阻 / 时序违规 只摘最终几行 + report 摘要
#   每项 ≤ 若干行，总量 <10KB → git push 手机端几乎零流量
#
# 规则：永远只读，不移动大文件；产生的小文本才是唯一需要提交的东西。

set src_dir [file normalize [file join [pwd] "" ]]

if {$argc < 1} {
    puts "用法: gw_sh mk_diag.tcl <OUT目录>"
    exit 1
}
set out_dir [lindex $argv 0]

# ---- 收集候选取证文件（report/日志/时序，按大小排）----
set files [list]
foreach f [glob -nocomplain -directory $out_dir *] {
    if {[file isfile $f]} { lappend files $f }
}
# 这里不读大文件内容，只按"名含关键词"先挑，再各截尾部
set wanted [list]
foreach f $files {
    set name [file tail $f]
    if {[string match -nocase "*timing*" $name] || [string match -nocase "*congest*" $name] \
        || [string match -nocase "*util*" $name] || [string match -nocase "*.log" $name] \
        || [string match -nocase "*report*" $name]} {
        lappend wanted $f
    }
}
# 若上面一个都没中，兜底取全部文件按修改时间最新的前 6 个
if {[llength $wanted] == 0} { set wanted $files }

puts "=== 抽取 $out_dir 诊断（共 [llength $wanted] 个候选） ==="

set out ""
append out "# PnR 诊断: $out_dir\n"
append out "# 生成时间: [clock format [clock seconds] -format %Y-%m-%d_%H%M%S]\n"

foreach f $wanted {
    if {![file exists $f]} continue
    set sz [file size $f]
    set tail_lines 30
    set fp [open $f r]
    # 只读尾部避免大文件全进内存
    set lines [list]
    set n 0
    while {[gets $fp line] >= 0} {
        lappend lines $line
        if {[llength $lines] > $tail_lines} { set lines [lrange $lines 1 end] }
        incr n
    }
    close $fp
    set tag [file tail $f]
    append out "\n--- $tag  <${sz}B, ${n} 行, 尾部 ${tail_lines} 行> ---\n"
    foreach l $lines { append out "  $l\n" }
    if {[string length $out] > 200000} {
        puts "WARN: 诊断已超 200KB，截断（只保留更小项）"
        break
    }
}

# ---- 状态判定 ----
set status "PNR-DONE"
if {[string first "FAIL" $out] >= 0 || [string first "Error" $out] >= 0} {
    set status "PR-FAIL"
}
if {[string first "congestion" [string tolower $out]] >= 0 || [string first "congest" [string tolower $out]] >= 0} {
    append status "-CONGEST"
}

set diag_file "$src_dir/diag_$tag.txt"
set fp [open $diag_file w]
puts $fp "status = $status"
puts $fp $out
close $fp
puts "=== 诊断已落盘: $diag_file (status=$status) -> 提交此文件即可 ==="
run close