# launch_macsplit_dontouch.ps1 — 启动 gw_sh 跑 macsplit_dontouch（syn_dont_touch 修复）实验
#
# 用法（由 Start-Process 后台运行，勿阻塞主会话）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch_macsplit_dontouch.ps1 2 0
#
# 产出:
#   <OUT>/macsplit_dontouch_pid.txt
#   <OUT>/macsplit_dontouch_run.log / .err
#   <OUT>/macsplit_dontouch_exit.txt

param(
    [int]$RouteOpt = 2,
    [int]$PlaceOpt = 0
)

$ErrorActionPreference = "Stop"
$GW  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$TCL = "F:\sram\sram\rtl\13_mega138k\build_macsplit_dontouch.tcl"
$OUT = "F:\sram\sram\out\138k_pro\macsplit_dontouch"

if (-not (Test-Path -LiteralPath $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }

$argsList = @($TCL, "$RouteOpt", "$PlaceOpt")
$p = Start-Process -FilePath $GW -ArgumentList $argsList -WorkingDirectory $OUT `
    -RedirectStandardOutput "$OUT\macsplit_dontouch_run.log" `
    -RedirectStandardError  "$OUT\macsplit_dontouch_run.log.err" `
    -PassThru -WindowStyle Hidden

$p.Id | Set-Content -LiteralPath "$OUT\macsplit_dontouch_pid.txt"
$start = Get-Date

$p.WaitForExit()
Start-Sleep -Milliseconds 500
$p.Refresh()
$code = $p.ExitCode
if ($null -eq $code) { $code = "(empty)" }
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
"[start=$($start.ToString('yyyy-MM-dd HH:mm:ss'))] [exit=$code] [elapsed=$elapsed s]" | Set-Content -LiteralPath "$OUT\macsplit_dontouch_exit.txt"
