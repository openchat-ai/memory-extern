# launch_macsplit_smoke.ps1 — 后台启动 gw_sh 跑 macsplit_smoke（收敛位流，含 CST）
#
# 用法（O 由上层 Start-Process 独立后台运行，勿在前台 WaitForExit 阻塞主会话）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch_macsplit_smoke.ps1 2 3 100
# 参数: RouteOpt PlaceOpt MaxFanout
#
# 产出:
#   <OUT>/macsplit_smoke_pid.txt
#   <OUT>/macsplit_smoke_run.log / .err
#   <OUT>/macsplit_smoke_exit.txt

param(
    [int]$RouteOpt = 2,
    [int]$PlaceOpt = 3,
    [int]$MaxFanout = 100
)

$ErrorActionPreference = "Stop"
$GW  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$TCL = "F:\sram\sram\rtl\13_mega138k\build_macsplit_smoke.tcl"
$OUT = "F:\sram\sram\out\138k_pro\macsplit_smoke"

if (-not (Test-Path -LiteralPath $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }

$argsList = @($TCL, "$RouteOpt", "$PlaceOpt", "$MaxFanout")
$p = Start-Process -FilePath $GW -ArgumentList $argsList -WorkingDirectory $OUT `
    -RedirectStandardOutput "$OUT\macsplit_smoke_run.log" `
    -RedirectStandardError  "$OUT\macsplit_smoke_run.log.err" `
    -PassThru -WindowStyle Hidden

$p.Id | Set-Content -LiteralPath "$OUT\macsplit_smoke_pid.txt"
$start = Get-Date

$p.WaitForExit()
Start-Sleep -Milliseconds 500
$p.Refresh()
$code = $p.ExitCode
if ($null -eq $code) { $code = "(empty)" }
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
"[start=$($start.ToString('yyyy-MM-dd HH:mm:ss'))] [exit=$code] [elapsed=$elapsed s]" | Set-Content -LiteralPath "$OUT\macsplit_smoke_exit.txt"
