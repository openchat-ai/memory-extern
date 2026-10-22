# spawn_detached.ps1 — 彻底脱离的进程启动 (2026-10-22)
# 为什么要它: 用 Start-Process 起的子进程仍在调用者的进程树里, 且会持有
#   调用者的 stdout/stderr 管道 → 上层(工具/会话)会一直等它结束, 表现为
#   "脚本一直占着主进程"。Win32_Process::Create 由 WMI 服务创建进程,
#   与调用者无父子关系、不继承管道 → 调用方立刻返回。
#
# 用法:
#   powershell -File spawn_detached.ps1 -Exe "C:\path\prog.exe" -Arg "a","b" -Log "C:\path\out.log"
# 输出: "spawned pid=<id>"

param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [string[]]$Arg = @(),
    [Parameter(Mandatory=$true)][string]$Log
)

$argStr = ($Arg | ForEach-Object { '"' + $_ + '"' }) -join ' '
$cmd = '"{0}" {1} > "{2}" 2>&1' -f $Exe, $argStr, $Log
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd }
if ($r.ReturnValue -ne 0) {
    Write-Error "spawn 失败: ReturnValue=$($r.ReturnValue)"
    exit 1
}
Write-Output "spawned pid=$($r.ProcessId) exe=$Exe log=$Log"
