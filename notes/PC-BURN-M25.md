# PC-BURN-M25 — M25 主线烧录收敛清单 (PC 侧承接)

## 输入件 (termux 已交, git 当前)
- rtl/13_mega138k/board_decode_top.v   (整包顶层, GOOD 双证 led[3])
- rtl/13_mega138k/decode_auto_core.v   (SELFDRV=1 自驱闭环; STRESS=0 默认关缺陷窗)
- rtl/13_mega138k/{route_asm,router_sel,attn_inner_ctl,head_vprune,vocab_prune,output_head}_sf.v
- rtl/34_assembler/assembler.v ... (7 产品件, 零改动)
- cst: mega138k_engine.cst (sys_clk P16=50MHz 直连 rst K16 led M25/R26/L20/J14)

## 已验证 (termux)
- yosys 0.68 synth_gowin -top board_decode_top 全 14 文件 rc=0
  (占位数据面折叠后 LUT540+ALU366+FF616; 激活面真账 PC 用真数据面重估)
- core_selftest: done@162, a_words=128, 内容级哈希 0104bef0 同seed复现
- board_good_tb: GOOD(led[3]) 帧3起, 双证 (每帧+128词 && 内容流活跃)

## 执行序
1. 上游 Gowin EDA: read netlist (译出) + cst + .sdc (make .sdc: sys_clk 50MHz create_clock)
2. P&R 四个 option 排列 (参考 macsplit smoke: route=2 place=3 max_fanout=100)
3. 检查时序: Fmax 目标 ≥50MHz (逻辑深度预算见 SF12+ P8: 余量充裕; 关键链3 fk ~19级)
   - 若 >124MHz 兴趣: fk 加入两拍流水再收敛 (P8 建议)
4. 烧录 SRAM (JTAG 15MHz, 实测 30s 烧完; 见下方"烧录操作坑"第 1 条 —— **不要写 8MHz**,
   那个值不存在, 传了会被忽略并实际跑 15MHz)
5. 板验判活:
   - LED[0] 心跳 (div[22] 慢闪) ; LED[2]=done 帧内高; LED[3]=GOOD 数帧后常亮; LED[1]=busy strobe
6. 读回/观测: out_data/out_expert 帧流 (切片词内容=预灌值, 与 core_selftest 基准可比)

## 已知缺陷复查项
- DC01 (SF12b): 信用停摆窗下 assembler 切片相位错位 (前71词一致, 后48词 +0x20 偏移)
  - 默认 STRESS=0 (板上无停摆) 不影响; 若上游信用波动设计, PC 侧修 assembler 层握手
    (S_TAKE 显式 in_valid 连续, 或 router layer_done 对齐) 后回归 core_stress_tb。
- 词表预灌: slice LUT 用 wr 接口预灌 (值=序号语义已验); 真词表数据 PC 替换 wr_data。

## 烧录操作坑 (2026-10-21 实机踩到, 逐条都有代价)
1. **`--frequency` 没有 8MHz 这个值**。合法值只有:
   `2.5MHz; 2MHz; 15MHz; 10MHz; 1.5MHz; 1.1MHz; 0.9MHz; 0.75MHz; 0.5MHz; 0.3MHz; 0.4MHz; 0.1MHz; 0.02MHz`
   传 `8` 匹配不到 → 工具自行挑 15MHz (日志 `Frequency Updated: "15MHz"`)。
   本文件此前记的"8MHz 稳定 / 15MHz 曾 20% 失败"**是错的**: 那些"8MHz"实际跑的是 15MHz。
   稳妥用 **15MHz**(实测 30s 烧完) 或默认 2.5MHz; 扫链默认就是 2.5MHz。
2. **进度条用 `\r` 不换行** → 任何截断管道 (如 `Select-Object -First N`) 会让
   子进程 stdout 写失败**当场死亡**(2026-10-21 实测 15MHz 烧到 35% 被掐死, 退出码 -1);
   而重定向到文件则是 **4KB 块缓冲**, 进度全憋在缓冲里 (0 字节) 看不见。
   正确做法: `& $exe ... 2>&1 | Tee-Object -FilePath $log` (实时上屏 + 落盘, 不截断)。
3. **15MHz 烧录中断 → 器件需断电复位**。被掐断后器件停在 JTAG 中途, 后续
   烧录与 `--scan` 都会**满负荷空转零应答**(2026-10-21 实测: 烧录进程 660s CPU /
   0 字节日志, 扫链 120s 无输出)。此时只能断电重上电。
4. **板级 LED 极性 = 共阳低亮** (J14/R26/L20/M25/N21/N23, 见 periph_smoke.cst 注释
   "共阳低亮") → **逻辑 0 才点亮**; 仓库已烧通过的 board_top.v / board_freq800_sentry.v
   一律写 `~signal`。**极性自检口诀: 按住复位不放 → 六个信号全被清 0 → 六盏灯应全亮**;
   若全灭则极性反了。(2026-10-21 板_decode_top 首烧就栽在这: LED 接成"1=亮",
   导致板上"条件成立=灯灭", 读数与实际完全相反, 差点误判成"挂死")
5. 烧录前先确认无残留 `programmer.exe` (GUI 会独占 USB 调试器);
   烧完别断电 —— SRAM 易失, 断电即失。
6. **"USB JTAG&UART" 那根线的 UART 侧不是 FPGA 用户 IO**: 它接的是 **AE350 RISC-V
   硬核自己的 UART** (SOM 引脚 N16/P15, 网名 FPGA_TXD/RXD)。N16 是 CPU 专用脚
   (Gowin 报 `PR2017: the location is a dedicated pin (CPU)`), 所以 FPGA 用户逻辑
   **接不进那个 COM 口**。要让用户逻辑跟 PC 说话, 走 **40P 排针**
   (pin_header[0]=U16 接 uart_rx / pin_header[1]=V16 接 uart_tx) + 一个 **USB-TTL
   转接头**: 转接头 RX←V16, TX→U16, GND↔GND。
   另一条路是给 AE350 跑固件当转发器 (工程量大得多, 以后再说)。
7. **烧录中途失败 → 器件可能不接 JTAG 了** (扫链报 "No Gowin devices found!",
   换 1/2.5/10/15MHz 全一样) → **只能断电重上电**。2026-10-21 撞过两次。
8. **Gowin 前端的语法限制** (写新模块必踩, 2026-10-21 一次全撞完):
   - `end else <裸语句>` → `EX2656 'else' used in incorrect context` → else 单独成行 + begin/end
   - SV 转换 `N'(x)` → `EX3863 Syntax error near '''` → 改用 localparam
   - 输入脚的 `IO_PORT` 不能给 `DRIVE=8` → `CT1108 Illegal port attribute value` → 改 DRIVE=OFF
   - `reg` 不能同时被 `assign` 驱动 → `EX3805 Concurrent assignment to a non-net` → 改 wire
   - iverilog 收这些写法, 只有 Gowin 前端拒 → **新模块必须用 Gowin 综合实跑一遍才算过**
9. **Gowin 综合会截断重命名长网名**: 顶层 wire `lcd_clk_35` → 网表里变成 **`lcd_clk_d`**
   → SDC 里 `create_clock ... [get_nets {lcd_clk_35}]` 报
   `TA2003 Can't set timing constraint to object` → **约束要写综合后的名字**(引擎板
   mega138k_engine.sdc 写的就是 `lcd_clk_d`)。查真名的办法: 综合完 grep
   `impl/gwsynthesis/<top>.vg` 里的网名。
10. **仿真里 Gowin 原厂 PLL 原语(PLL) iverilog 不认** → `Unknown module type: PLL`。
    写一个仿真替身 (直通时钟) 顶替, 真综合仍用原厂 PLL 模块。

