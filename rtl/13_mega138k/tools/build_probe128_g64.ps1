# build_probe128_g64.ps1 - thin wrapper: A-experiment 128-lane with GROUP_LANES=64 (2 groups x 64).
# Tests whether the 128-lane deadloop is caused by the top-level multi-group merge (TOP_LANES=4).
# If this converges, deadloop is the 4-group top merge -> gives upstream a direct RTL workaround.
# gold standard: probe128_g64/board_top_probe128_g64/impl/pnr/board_top_probe128_g64.rpt.txt

$ErrorActionPreference = "Continue"
$runner = Join-Path $PSScriptRoot "build_with_deadline.ps1"
$tcl    = "F:\sram\sram\rtl\13_mega138k\build_probe128_g64.tcl"
$log    = "F:\sram\sram\out\138k_pro\probe128_g64_run.log"
$state  = "F:\sram\sram\out\138k_pro\probe128_g64_state.txt"
$rpt    = "F:\sram\sram\out\138k_pro\probe128_g64\board_top_probe128_g64\impl\pnr\board_top_probe128_g64.rpt.txt"

# 128-lane candidate. If still deadloop -> DEADLOOP auto-kill ~20min. If rescued by 2x64 -> COMPLETED ~5min.
powershell -WindowStyle Hidden -NoProfile -File $runner `
    -TclFile $tcl -RptPath $rpt -Log $log -StateFile $state `
    -TimeoutSec 1800 -DeadlockAfter 1200 -PollSec 5