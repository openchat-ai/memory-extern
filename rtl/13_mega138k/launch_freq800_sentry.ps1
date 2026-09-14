# launch_freq800_sentry.ps1 — 启动 gw_sh 跑 800 哨兵 PnR，记录退出码
# 用法（可后台）：powershell -NoProfile -ExecutionPolicy Bypass -File launch_freq800_sentry.ps1
# 产出:
#   <OUT>/freq800_sentry_pid.txt     gw_sh 进程 PID（供 watch_pnr.ps1 -GwPid）
#   <OUT>/freq800_sentry_run.log     gw_sh stdout
#   <OUT>/freq800_sentry_run.log.err
#   <OUT>/freq800_sentry_exit.txt    "[start=...] [exit=...] [elapsed=... s]"
param(
    [int]$RouteOpt = 2,
    [int]$PlaceOpt = 3,
    [int]$MaxFanout = 100
)

$ErrorActionPreference = "Stop"
$GW  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$TCL = "F:\sram\sram\rtl\13_mega138k\build_freq800_sentry.tcl"
$OUT = "F:\sram\sram\out\138k_pro\freq800_sentry"

if (-not (Test-Path -LiteralPath $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }

$argsList = @($TCL, "$RouteOpt", "$PlaceOpt", "$MaxFanout")
$p = Start-Process -FilePath $GW -ArgumentList $argsList -WorkingDirectory $OUT `
    -RedirectStandardOutput "$OUT\freq800_sentry_run.log" `
    -RedirectStandardError  "$OUT\freq800_sentry_run.log.err" `
    -PassThru -WindowStyle Hidden

$p.Id | Set-Content -LiteralPath "$OUT\freq800_sentry_pid.txt"
$start = Get-Date

$p.WaitForExit()
$code = $p.ExitCode
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
"[start=$($start.ToString('yyyy-MM-dd HH:mm:ss'))] [exit=$code] [elapsed=$elapsed s]" | Set-Content -LiteralPath "$OUT\freq800_sentry_exit.txt"