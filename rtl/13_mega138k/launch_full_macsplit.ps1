# launch_full_macsplit.ps1 — 启动 gw_sh 跑 full_macsplit 实验，记录退出码
#
# 用法（由 Start-Process 后台运行，勿阻塞主会话）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch_full_macsplit.ps1 2 0
#
# 产出:
#   <OUT>/full_macsplit_pid.txt
#   <OUT>/full_macsplit_run.log / .err
#   <OUT>/full_macsplit_exit.txt

param(
    [int]$RouteOpt = 2,
    [int]$PlaceOpt = 0
)

$ErrorActionPreference = "Stop"
$GW  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$TCL = "F:\sram\sram\rtl\13_mega138k\build_full_macsplit.tcl"
$OUT = "F:\sram\sram\out\138k_pro\full_macsplit"

if (-not (Test-Path -LiteralPath $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }

$argsList = @($TCL, "$RouteOpt", "$PlaceOpt")
$p = Start-Process -FilePath $GW -ArgumentList $argsList -WorkingDirectory $OUT `
    -RedirectStandardOutput "$OUT\full_macsplit_run.log" `
    -RedirectStandardError  "$OUT\full_macsplit_run.log.err" `
    -PassThru -WindowStyle Hidden

$p.Id | Set-Content -LiteralPath "$OUT\full_macsplit_pid.txt"
$start = Get-Date

$p.WaitForExit()
$code = $p.ExitCode
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
"[start=$($start.ToString('yyyy-MM-dd HH:mm:ss'))] [exit=$code] [elapsed=$elapsed s]" | Set-Content -LiteralPath "$OUT\full_macsplit_exit.txt"