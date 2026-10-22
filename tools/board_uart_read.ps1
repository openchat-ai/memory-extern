# board_uart_read.ps1 — 板载 UART 通道读取 (Windows, 不需要 pyserial)
#
# 用法:
#   powershell -File tools\board_uart_read.ps1                 # 自动扫 COM 口, 打印板子吐的行
#   powershell -File tools\board_uart_read.ps1 -Port COM1      # 指定串口
#   powershell -File tools\board_uart_read.ps1 -Send 0x12      # 先发一个命令字节
#   powershell -File tools\board_uart_read.ps1 -Send 0x12 -Watch 20
#
# 行格式: F=<帧号> W=<词量> H=<帧哈希> A=<attn内积> L=<引擎层数> R=<rail帧> C=<末次命令>
# 命令字节: 低4位 = 覆盖 xext (候选窗半径), bit4 = 立刻手动触发一帧
param(
  [string]$Port = "",
  [int]$Baud = 115200,
  [string]$Send = "",
  [double]$Watch = 0,
  [int]$TimeoutMs = 300
)

Add-Type -AssemblyName System.IO.Ports

$ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
Write-Host "可用串口: $($ports -join ', ')" -ForegroundColor DarkGray

function Open-One($name) {
  $sp = New-Object System.IO.Ports.SerialPort $name, $Baud, "None", 8, "One"
  $sp.ReadTimeout = $TimeoutMs
  $sp.Open()
  return $sp
}

$sp = $null
if ($Port -ne "") {
  $sp = Open-One $Port
  Write-Host "已打开 $Port @ $Baud" -ForegroundColor Cyan
} else {
  foreach ($p in $ports) {
    try { $sp = Open-One $p; Write-Host "已打开 $p @ $Baud" -ForegroundColor Cyan; break }
    catch { Write-Host "  $p 打开失败: $($_.Exception.Message)" -ForegroundColor DarkGray }
  }
  if ($sp -eq $null) { Write-Host "没有能打开的串口" -ForegroundColor Red; exit 1 }
}

if ($Send -ne "") {
  $b = [Convert]::ToInt32($Send, 16) -band 0xFF
  $sp.Write([byte]$b)
  Write-Host "--> 已发命令字节 0x$('{0:x2}' -f $b) (低4位=xext, bit4=手动触发一帧)" -ForegroundColor Green
}

$buf = ""
$end = (Get-Date).AddSeconds($(if ($Watch -gt 0) { $Watch } else { 3600 }))
while ((Get-Date) -lt $end) {
  try {
    $chunk = $sp.ReadExisting()
  } catch { $chunk = "" }
  if ($chunk -ne "") {
    $buf += $chunk
    while ($buf.Contains("`n")) {
      $i = $buf.IndexOf("`n")
      $line = $buf.Substring(0, $i).TrimEnd("`r")
      $buf = $buf.Substring($i + 1)
      Write-Host $line
    }
  } else { Start-Sleep -Milliseconds 50 }
}
$sp.Close()
Write-Host "--- 结束 ---" -ForegroundColor DarkGray
