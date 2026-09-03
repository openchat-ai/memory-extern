# launch_periph_smoke.ps1 — 后台启动全外设冒烟 PnR（不占主会话）
# 用法：powershell -File launch_periph_smoke.ps1 [route] [place] [max_fanout]
# 产物：out/138k_pro/periph_smoke/ + periph_smoke_result.txt
param(
    [string]$Route = "2",
    [string]$Place = "3",
    [string]$MaxFanout = "100"
)

$gwsh = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$tcl  = "F:\sram\sram\rtl\13_mega138k\build_periph_smoke.tcl"
$log  = "F:\sram\sram\out\138k_pro\periph_smoke\run_periph_smoke.log"

New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

$argsArr = @($tcl, $Route, $Place, $MaxFanout)
$p = Start-Process -FilePath $gwsh -ArgumentList $argsArr `
     -RedirectStandardOutput $log -RedirectStandardError "$log.err" `
     -WindowStyle Hidden -PassThru

Write-Output "PERIPH_SMOKE PID=$($p.Id) 已后台启动 -> $log"
