# launch_lcd_test.ps1 — 独立 LCD 小位流 (调显示迭代用: 1~2 分钟, 而整包 16 分钟)
# 彻底脱离主进程 (spawn_detached.ps1 → Win32_Process::Create)
$ErrorActionPreference = "Stop"
$bin  = "D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin"
$tcl  = "F:\sram\sram\rtl\13_mega138k\build_lcd_test.tcl"
$out  = "F:\sram\sram\out\lcd_test.out"

Remove-Item $out -ErrorAction SilentlyContinue
& powershell -NoProfile -ExecutionPolicy Bypass `
      -File "F:\sram\sram\rtl\13_mega138k\spawn_detached.ps1" `
      -Exe "$bin\gw_sh.exe" -Arg @($tcl) -Log $out
