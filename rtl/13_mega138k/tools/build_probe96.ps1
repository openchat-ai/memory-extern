# build_probe96.ps1 - thin wrapper launching the deadline runner for the 96-lane threshold test.
# Backs off immediately (background); never blocks the main session.
# gold standard .rpt.txt: out/138k_pro/probe96/board_top_probe96/impl/pnr/board_top_probe96.rpt.txt

$ErrorActionPreference = "Continue"
$runner = Join-Path $PSScriptRoot "build_with_deadline.ps1"
$tcl    = "F:\sram\sram\rtl\13_mega138k\build_probe96.tcl"
$log    = "F:\sram\sram\out\138k_pro\probe96_run.log"
$state  = "F:\sram\sram\out\138k_pro\probe96_state.txt"
$rpt    = "F:\sram\sram\out\138k_pro\probe96\board_top_probe96\impl\pnr\board_top_probe96.rpt.txt"

# 96-lane threshold: 64 converges (~5min), 128 deadloops. 30min hard cap + 20min deadloop gap.
powershell -WindowStyle Hidden -NoProfile -File $runner `
    -TclFile $tcl -RptPath $rpt -Log $log -StateFile $state `
    -TimeoutSec 1800 -DeadlockAfter 1200 -PollSec 5