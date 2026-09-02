# watch_pnr.ps1 — PnR 真实信号判读器（不靠 log 猜测）
#
# 判据全部来自可观测真实信号：
#   1. 进程存活 / CPU 增量 / WorkingSet   —— 进程级心跳
#   2. 产物文件出现（.rpt.txt / .fs / .bit）—— 终结判据
#   3. log 只当"一次性事件源"（出现 [NN%] phase 标记 / ERROR PR0004 才有效），
#      绝不把"log 长时间不动"当作卡死判据（Routing Phase 1 期间本就不写 log）。
#
# 状态机（输出 state）:
#   ACTIVE          进程存活且 CPU 增量≈采样间隔（单核满载在算）
#   STUCK           进程存活但 CPU 增量≈0 且 WS 持平，连续 MaxStuck 次
#   FAIL_ROUTE(N)   .rpt.txt 出现且含 ERROR(PR0004) N unrouted
#   PNR_DONE        .rpt.txt 出现且无 PR0004（等 .fs 确认 bitstream）
#   BITSTREAM_DONE  .fs/.bit 出现（整套成功）
#   DIED_EARLY      进程消失且无 rpt/fs 产物（被 kill/崩溃，本次 exit=-1 即此态）
#   NOPROC          从未捕获到进程
#
# 用法:
#   watch_pnr.ps1 -GwPid 1234 -ResultDir F:\...\impl\pnr -Once
#   watch_pnr.ps1 -GwPid 1234 -ResultDir F:\...\impl\pnr -EventLog F:\...\run.log
#   watch_pnr.ps1 -GwPid 1234 -ResultDir F:\...\impl\pnr -Loop -Interval 30 -StateFile C:\tmp\w.csv
#   （Loop 模式由 Start-Process 后台运行，状态落盘，主会话做一次性检查时传 -Once 复用 StateFile）
#
# 参数:
#   -GwPid        gw_sh 进程 ID（必填）
#   -ResultDir  pnr 结果目录（监控 .rpt.txt/.fs/.bit 出现）
#   -EventLog   gw_sh 输出日志（可选，仅提取最新 phase/ERROR 标记作 note，不参与判据）
#   -Interval   采样间隔秒（Loop 模式，默认 30）
#   -MaxStuck   连续低活性判定 STUCK 的次数（默认 4）
#   -Once       一次性采样输出一行状态（主会话快速检查用）
#   -Loop       后台循环采样落盘
#   -StateFile  状态持久化文件（Loop 写 / Once 读，默认 %TEMP%\watch_pnr_state.json）
#   -MaxTotal   总监控时长秒，超时强制输出 TIMEOUT 并退出（默认 3600）

param(
    [Parameter(Mandatory=$true)][int]$GwPid,
    [Parameter(Mandatory=$true)][string]$ResultDir,
    [string]$EventLog = "",
    [int]$Interval = 30,
    [int]$MaxStuck = 4,
    [switch]$Once,
    [switch]$Loop,
    [string]$StateFile = "",
    [int]$MaxTotal = 3600
)

$ErrorActionPreference = "Stop"
if (-not $StateFile) { $StateFile = Join-Path $env:TEMP "watch_pnr_state.json" }

function Get-LatestPhase {
    param([string]$Log)
    if (-not $Log -or -not (Test-Path -LiteralPath $Log)) { return "" }
    $last = ""
    $m = Select-String -LiteralPath $Log -Pattern '\[(\d+)%\]\s+\w+\s+Phase\s+\d+\s+completed|ERROR\s+\(PR0004\).*?(\d+)\s+unrouted' -AllMatches -ErrorAction SilentlyContinue
    if ($m) { $last = $m[-1].Matches[0].Value }
    return $last
}

function Get-ProductState {
    # 产物判据：rpt/fs/bit 是否出现
    $rpt = Get-ChildItem -LiteralPath $ResultDir -Filter *.rpt.txt -ErrorAction SilentlyContinue | Select-Object -First 1
    $par = Split-Path -Parent $ResultDir
    $fs  = Get-ChildItem -LiteralPath $ResultDir -Filter *.fs -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $fs) { $fs = Get-ChildItem -LiteralPath $par -Filter *.fs -ErrorAction SilentlyContinue | Select-Object -First 1 }
    $bit = Get-ChildItem -LiteralPath $ResultDir -Filter *.bit -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($fs -or $bit) {
        $name = if ($fs) { $fs.Name } else { $bit.Name }
        return @{ State = "BITSTREAM_DONE"; Detail = $name }
    }
    if ($rpt) {
        $hasErr = Select-String -LiteralPath $rpt.FullName -Pattern 'ERROR\s+\(PR0004\).*?(\d+)\s+unrouted' -AllMatches -ErrorAction SilentlyContinue
        if ($hasErr) {
            $n = $hasErr[-1].Matches[0].Groups[1].Value
            return @{ State = "FAIL_ROUTE($n)"; Detail = $rpt.Name }
        }
        $hasTotal = Select-String -LiteralPath $rpt.FullName -Pattern 'Total Time and Memory Usage' -ErrorAction SilentlyContinue
        if ($hasTotal) {
            return @{ State = "PNR_DONE"; Detail = $rpt.Name }
        }
        return @{ State = "RPT_EARLY"; Detail = $rpt.Name }
    }
    return @{ State = ""; Detail = "" }
}

# 读取/初始化上次采样
$prev = $null
if (Test-Path -LiteralPath $StateFile) {
    try { $prev = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json } catch { $prev = $null }
}
if (-not $prev) {
    $p0 = Get-Process -Id $GwPid -ErrorAction SilentlyContinue
    $prev = [pscustomobject]@{
        Ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Cpu = if ($p0) { $p0.CPU } else { 0 }
        Ws = if ($p0) { [math]::Round($p0.WorkingSet64/1MB,0) } else { 0 }
        Alive = [bool]$p0
        StuckCnt = 0
    }
}

function Write-State {
    param($obj)
    $obj | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Sample-Once {
    $p = Get-Process -Id $GwPid -ErrorAction SilentlyContinue
    $now = Get-Date
    $alive = [bool]$p
    $cpu  = if ($alive) { $p.CPU } else { $prev.Cpu }
    $ws   = if ($alive) { [math]::Round($p.WorkingSet64/1MB,0) } else { $prev.Ws }

    $dCpu = $cpu - $prev.Cpu
    $dWs  = $ws - $prev.Ws
    $phase = Get-LatestPhase -Log $EventLog

    if (-not $alive) {
        $prod = Get-ProductState
        if ($prod.State) { return $prod }
        return @{ State = "DIED_EARLY"; Detail = "no rpt/fs, lastPhase=$phase" }
    }

    # 进程活着：看 CPU 增量
    $elapsedSec = [math]::Max(0.001, ($now - [datetime]::ParseExact($prev.Ts, "yyyy-MM-dd HH:mm:ss", $null)).TotalSeconds)
    $ratio = $dCpu / $elapsedSec
    if ($ratio -ge 0.8) {
        $stuck = 0
        return @{ State = "ACTIVE"; Detail = "cpu+$([math]::Round($dCpu,1))s/$([math]::Round($elapsedSec,1))s ws=$ws phase=$phase" }
    }
    # 低活性：CPU 停 + WS 平 才算疑似卡
    if ($ratio -lt 0.02 -and [math]::Abs($dWs) -lt 5) {
        $stuck = $prev.StuckCnt + 1
        if ($stuck -ge $MaxStuck) {
            return @{ State = "STUCK"; Detail = "cpu+$([math]::Round($dCpu,2))s ws平 $stuck 次, lastPhase=$phase" }
        }
        return @{ State = "LOW_ACTIVITY"; Detail = "cpu+$([math]::Round($dCpu,2))s 第 $stuck/$MaxStuck 次" }
    }
    return @{ State = "ACTIVE"; Detail = "cpu+$([math]::Round($dCpu,1))s ratio=$([math]::Round($ratio,2)) ws=$ws phase=$phase" }
}

if ($Loop) {
    $tStart = Get-Date
    while ($true) {
        $p = Get-Process -Id $GwPid -ErrorAction SilentlyContinue
        if (-not $p) {
            $r = Sample-Once
            "$(Get-Date -Format 'HH:mm:ss') | $($r.State) | $($r.Detail)"
            break
        }
        $r = Sample-Once
        $line = "$(Get-Date -Format 'HH:mm:ss') | $($r.State) | $($r.Detail)"
        $line
        # 更新 prev 供下次
        $np = Get-Process -Id $GwPid -ErrorAction SilentlyContinue
        if ($np) {
            $prev = [pscustomobject]@{
                Ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                Cpu = $np.CPU
                Ws = [math]::Round($np.WorkingSet64/1MB,0)
                Alive = $true
                StuckCnt = if ($r.State -eq "LOW_ACTIVITY") { $prev.StuckCnt + 1 } elseif ($r.State -eq "STUCK") { $MaxStuck } else { 0 }
            }
            Write-State $prev
        }
        if (((Get-Date) - $tStart).TotalSeconds -gt $MaxTotal) {
            "TIMEOUT: exceeded $MaxTotal s"
            break
        }
        Start-Sleep -Seconds $Interval
    }
}
else {
    $r = Sample-Once
    # 更新 prev 落盘供下次
    $p = Get-Process -Id $GwPid -ErrorAction SilentlyContinue
    if ($p) {
        $prev = [pscustomobject]@{
            Ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            Cpu = $p.CPU
            Ws = [math]::Round($p.WorkingSet64/1MB,0)
            Alive = $true
            StuckCnt = if ($r.State -eq "LOW_ACTIVITY") { $prev.StuckCnt + 1 } elseif ($r.State -eq "STUCK") { $MaxStuck } else { 0 }
        }
        Write-State $prev
    }
    "$(Get-Date -Format 'HH:mm:ss') | $($r.State) | $($r.Detail)"
}