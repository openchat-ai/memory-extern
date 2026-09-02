# launch_eng200.ps1 — 启动 gw_sh 跑 eng200 实验，记录退出码（区分 kill vs crash）
#
# 用法（由 Start-Process 后台运行，勿阻塞主会话）:
#   powershell -NoProfile -ExecutionPolicy Bypass -File launch_eng200.ps1 2 0
#   （argv1=route_option  argv2=place_option）
#
# 产出:
#   <OUT>/eng200_pid.txt    gw_sh 进程 PID（启动后立即写，供 watch_pnr.ps1 -GwPid）
#   <OUT>/eng200_run.log    gw_sh stdout（同 build_eng200.tcl 直接跑）
#   <OUT>/eng200_run.log.err
#   <OUT>/eng200_exit.txt   "[start=...] [exit=...] [elapsed=... s]"（进程结束后写）
#
# exit=-1 且无 result/产物 = 被 TerminateProcess 强杀（无 Tcl catch 机会）
# exit=  0  = run all 正常返回（read eng200_result.txt）
# exit 其它 = gw_sh 自己退出（崩溃/异常），配合事件日志/WER 定位

param(
    [int]$RouteOpt = 2,
    [int]$PlaceOpt = 0
)

$ErrorActionPreference = "Stop"
$GW  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$TCL = "F:\sram\sram\rtl\13_mega138k\build_eng200.tcl"
$OUT = "F:\sram\sram\out\138k_pro\eng200"

if (-not (Test-Path -LiteralPath $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }

$argsList = @($TCL, "$RouteOpt", "$PlaceOpt")
$p = Start-Process -FilePath $GW -ArgumentList $argsList -WorkingDirectory $OUT `
    -RedirectStandardOutput "$OUT\eng200_run.log" `
    -RedirectStandardError  "$OUT\eng200_run.log.err" `
    -PassThru -WindowStyle Hidden

$p.Id | Set-Content -LiteralPath "$OUT\eng200_pid.txt"
$start = Get-Date

$p.WaitForExit()
$code = $p.ExitCode
$elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
"[start=$($start.ToString('yyyy-MM-dd HH:mm:ss'))] [exit=$code] [elapsed=$elapsed s]" | Set-Content -LiteralPath "$OUT\eng200_exit.txt"