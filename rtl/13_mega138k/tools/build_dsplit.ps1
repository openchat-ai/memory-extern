# build_dsplit.ps1 - thin wrapper: data-path-split experiment (128-lane acc_bus split into
# two independent 64-lane reduction blocks). Tests whether the 128-lane Routing Phase 1
# deadloop is the global 4096bit reduction fan-in (rescuable by data-path split) vs
# something else in the 128-lane array itself.
# gold standard: probe_dsplit/board_top_dsplit/impl/pnr/board_top_dsplit.rpt.txt

$ErrorActionPreference = "Continue"
$runner = Join-Path $PSScriptRoot "build_with_deadline.ps1"
$tcl    = "F:\sram\sram\rtl\13_mega138k\build_dsplit.tcl"
$log    = "F:\sram\sram\out\138k_pro\probe_dsplit_run.log"
$state  = "F:\sram\sram\out\138k_pro\probe_dsplit_state.txt"
$rpt    = "F:\sram\sram\out\138k_pro\probe_dsplit\board_top_dsplit\impl\pnr\board_top_dsplit.rpt.txt"

# Candidate path. If rx-gd this converges (~5min COMPLETED); if still deadloop -> DEADLOOP auto-kill ~20min.
powershell -WindowStyle Hidden -NoProfile -File $runner `
    -TclFile $tcl -RptPath $rpt -Log $log -StateFile $state `
    -TimeoutSec 1800 -DeadlockAfter 1200 -PollSec 5