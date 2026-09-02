# build_with_deadline.ps1 - unified gw_sh PnR runner with forced deadline + gold-standard (.rpt.txt) exit
#
# Purpose: all gw_sh PnR builds (probe/sweep/eng200/any tcl) use this runner.
#   Uses .rpt.txt as the ONLY authoritative "converged OK" signal; on timeout/deadloop
#   it kills the runaway process automatically. NEVER waits forever, NEVER blocks the main session.
#
# Exit paths (all automatic):
#   1. COMPLETED - polling finds <top>.rpt.txt appeared (Gowin only writes it after FULL PnR done)
#   2. DEADLOOP  - elapsed >= DeadlockAfter sec, still no .rpt.txt and process alive -> auto kill (routing stuck)
#   3. TIMEOUT   - hard upper bound TimeoutSec reached, still no .rpt.txt -> forced kill (safety net)
#   4. FAIL      - process exited by itself but no .rpt.txt (synthesis/exception error)
#
# Rationale (measured, see diag_sweep200_deadloop.txt):
#   - converged build: placement -> .db/.p written, routing -> .pr/.fs/.bin, then finally .rpt.txt
#   - deadloop: stuck in Routing Phase 1 (progress bar frozen at [60%]), .rpt.txt NEVER appears
#   - so .rpt.txt presence is the most reliable converged-vs-deadloop signal (better than CPU/mtime)
#
# Usage (launch in background, main session returns immediately):
#   powershell -WindowStyle Hidden -File build_with_deadline.ps1 `
#       -TclFile F:/.../build_probe.tcl -RptPath F:/.../impl/pnr/board_top_probe.rpt.txt `
#       -Log F:/.../probe_run.log -StateFile F:/.../probe_state.txt `
#       -TimeoutSec 1800 -DeadlockAfter 1200 -Mtls 200

param(
    [Parameter(Mandatory=$true)][string]$TclFile,
    [Parameter(Mandatory=$true)][string]$RptPath,
    [Parameter(Mandatory=$true)][string]$Log,
    [Parameter(Mandatory=$true)][string]$StateFile,
    [int]$TimeoutSec   = 1800,
    [int]$DeadlockAfter = 1200,
    [int]$PollSec      = 5,
    [string[]]$Mtls    = @()
)

$ErrorActionPreference = "Continue"
$gwsh = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\gw_sh.exe"
$start = Get-Date
$deadline = $start.AddSeconds($TimeoutSec)

"=== RUN start $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') Tcl=$TclFile Mtls=$($Mtls -join ' ') ===" |
    Out-File $Log -Encoding UTF8

# ---- launch gw_sh as background child, redirect stdout/stderr ----
$argsList = @($TclFile) + $Mtls
$proc = Start-Process -FilePath $gwsh -ArgumentList $argsList `
    -RedirectStandardOutput "$Log.out" -RedirectStandardError "$Log.err" `
    -WindowStyle Hidden -PassThru

Write-Output "build_with_deadline: PID=$($proc.Id) polling .rpt.txt @ $RptPath (Timeout=${TimeoutSec}s Deadlock=${DeadlockAfter}s)"

# ---- poll .rpt.txt (gold standard) ----
$completed = $false
$deadlocked = $false
$progressLogEmit = 0
while ((Get-Date) -lt $deadline) {
    # gold standard: .rpt.txt appeared => converged
    if (Test-Path $RptPath) { $completed = $true; break }

    # early deadloop: elapsed crossed DeadlockAfter with process still alive + no rpt => routing stuck
    $elSec = ((Get-Date) - $start).TotalSeconds
    $proc.Refresh()
    if (-not $proc.HasExited -and $elSec -ge $DeadlockAfter) {
        $deadlocked = $true
        break
    }
    if ($proc.HasExited) { break }

    # periodic progress note to log (does not block; keeps evidence of liveness)
    if ($elSec -ge $progressLogEmit + 120) {
        "[+$([math]::Round($elSec,0))s] still running, no .rpt.txt yet (PID=$($proc.Id))" |
            Add-Content $Log -Encoding UTF8
        $progressLogEmit = [math]::Round($elSec,0)
    }
    Start-Sleep -Seconds $PollSec
}
if (-not $completed -and (Test-Path $RptPath)) { $completed = $true }

$elapsedSec = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)

# ---- classify status ----
$status = "FAIL"
if ($completed) {
    $status = "COMPLETED"
} elseif ($proc.HasExited) {
    $status = "FAIL"
} elseif ($deadlocked) {
    $status = "DEADLOOP"
} else {
    $status = "TIMEOUT"
}

# ---- cleanup (only DEADLOOP/TIMEOUT force-kill; COMPLETED/FAIL already ended) ----
if (($status -eq "DEADLOOP" -or $status -eq "TIMEOUT") -and -not $proc.HasExited) {
    "  status=$status no .rpt.txt -> kill PID=$($proc.Id) (elapsed=${elapsedSec}s)" |
        Add-Content $Log -Encoding UTF8
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
    Get-Process gw_sh -ErrorAction SilentlyContinue |
        Where-Object { $_.StartTime -ge $start.AddSeconds(-2) } |
        ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
}

# ---- archive result ----
$result = [ordered]@{
    status    = $status
    elapsed_s = $elapsedSec
    rpt_seen  = (Test-Path $RptPath)
    top_tcl   = $TclFile
    routing   = $null
}
if ($completed) {
    $rpt = Get-Content $RptPath -Encoding UTF8 -ErrorAction SilentlyContinue
    $t = $rpt | Select-String -Pattern "Total Routing" | Select-Object -First 1
    $p = $rpt | Select-String -Pattern "Total Placement" | Select-Object -First 1
    if ($t) { $result.routing = $t.Line.Trim() }
    if ($p) { $result.placement = $p.Line.Trim() }
}
$result | ConvertTo-Json -Depth 3 | Out-File $StateFile -Encoding UTF8

"=== RUN done status=$status elapsed=${elapsedSec}s rpt_seen=$($result.rpt_seen) $(Get-Date -Format 'HH:mm:ss') ===" |
    Add-Content $Log -Encoding UTF8

Write-Output "build_with_deadline: FINISH status=$status elapsed=${elapsedSec}s rpt=$($result.rpt_seen) state=$StateFile"
exit 0