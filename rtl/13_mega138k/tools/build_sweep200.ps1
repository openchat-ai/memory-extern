# build_sweep200.ps1 - thin wrapper launching the deadline runner for the 200MHz sweep build.
# Backs off immediately (background); never blocks the main session.
# gold standard .rpt.txt: out/138k_pro/sweep_200m/board_top_sweep_200/impl/pnr/board_top.rpt.txt

$ErrorActionPreference = "Continue"
$runner = Join-Path $PSScriptRoot "build_with_deadline.ps1"
$tcl    = "F:\sram\sram\rtl\13_mega138k\build_sweep.tcl"
$log    = "F:\sram\sram\out\138k_pro\sweep_200m_run.log"
$state  = "F:\sram\sram\out\138k_pro\sweep_200m_state.txt"
$rpt    = "F:\sram\sram\out\138k_pro\sweep_200m\board_top_sweep_200\impl\pnr\board_top.rpt.txt"

# sweep 128-lane is KNOWN deadloop (no .rpt.txt ever). Use tight gap so it dies fast and archives DEADLOOP.
powershell -WindowStyle Hidden -NoProfile -File $runner `
    -TclFile $tcl -RptPath $rpt -Log $log -StateFile $state `
    -TimeoutSec 1800 -DeadlockAfter 900 -PollSec 5 -Mtls 200