# build_probe.ps1 - thin wrapper launching build_with_deadline.ps1 for the probe build.
# Backs off immediately (background), so it NEVER blocks the main opencode session.
# Force-quit safety is inside the deadline runner (gold standard: probe .rpt.txt).

$ErrorActionPreference = "Continue"
$runner = Join-Path $PSScriptRoot "build_with_deadline.ps1"
$tcl    = "F:\sram\sram\rtl\13_mega138k\build_probe.tcl"
$log    = "F:\sram\sram\out\138k_pro\probe_run.log"
$state  = "F:\sram\sram\out\138k_pro\probe_state.txt"
$rpt    = "F:\sram\sram\out\138k_pro\probe\board_top_probe\impl\pnr\board_top_probe.rpt.txt"

# probe converges in ~5-19min; 128-lane degenerates to deadloop. 30min hard cap + 20min deadloop gap.
powershell -WindowStyle Hidden -NoProfile -File $runner `
    -TclFile $tcl -RptPath $rpt -Log $log -StateFile $state `
    -TimeoutSec 1800 -DeadlockAfter 1200 -PollSec 5