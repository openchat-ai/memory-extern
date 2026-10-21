# launch_dtop_synth.ps1 — 后台跑 board_decode_top 综合（不占主线）
# 用法: powershell -File launch_dtop_synth.ps1 [all|synth]
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