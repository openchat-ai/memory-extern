# launch_dtop_synth.ps1 — 后台跑 board_decode_top 综合/PnR（不占主线）
# 用法: powershell -File launch_dtop_synth.ps1 [all|synth]
#   all   = 全量 综合+PnR   (~16 分钟)
#   synth = 只综合           (~5 分钟)
#
# 注: 增量 PnR 已实测**不可用** (2026-10-22):
#   PA2136 "placement matching 52.03% < threshold 80" → 工具拒绝复用布局,
#   退化重跑后 3560s (59min) vs 全量 994s (16.5min) = 慢 3.7 倍, 并抛
#   PR0004 "0 unrouted nets" 假错。根因: 本设计改动 (LCD 字库/字符串/字段)
#   会扩散到布局, 逐单元匹配率上不去。→ 脚本已删, 勿重开。
$ErrorActionPreference = "Stop"
$mode = if ($args.Count -ge 1) { $args[0] } else { "synth" }
$bin  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin"
$tcl  = "F:\sram\sram\rtl\13_mega138k\build_decode_top.tcl"
$out  = "F:\sram\sram\out\dtop_${mode}.out"
$err  = "F:\sram\sram\out\dtop_${mode}.err"
$pidf = "F:\sram\sram\out\dtop_${mode}.pid"

Remove-Item $out,$err,$pidf -ErrorAction SilentlyContinue

$p = Start-Process -FilePath "$bin\gw_sh.exe" `
        -ArgumentList $tcl, $mode `
        -WorkingDirectory $bin `
        -WindowStyle Hidden `
        -RedirectStandardOutput $out `
        -RedirectStandardError  $err `
        -PassThru

$p.Id | Out-File -FilePath $pidf -Encoding ascii -NoNewline
Write-Output "started pid=$($p.Id) mode=$mode"
Write-Output "stdout: $out"
Write-Output "stderr: $err"
Write-Output "结果文件: F:\sram\sram\rtl\13_mega138k\decode_top_result.txt"
Write-Output "综合日志: F:\sram\sram\out\138k_pro\decode_top\board_decode_top_r2p3\impl\gwsynthesis\board_decode_top.log"