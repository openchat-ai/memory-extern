# board_decode_top — 板级整包 PnR 结果 (decode 闭环 + 引擎判活, 可上硅)

> 机器读字段见同目录 `decode_top_result.txt` (纯 ASCII, 由 build_decode_top.tcl 写)。
> 本文件是人写的叙述版 (UTF-8)。最后更新: 2026-10-21 17:41。

```
mode = all   route_option = 2   place_option = 3   max_fanout = 100
elapsed_s = 746   status = DONE
```

## Resources (pnr/rpt.txt)

| 项 | 值 | 占器件 138,240 |
|---|---|---|
| LUT | 21,260 | 15.4% |
| ALU | 508 | — |
| LUT+ALU 合计 | **21,888** | **15.8%** |
| Register | 4,668 | 3.4% |
| MULTALU27X18 | 3 | — |
| MULTADDALU12X12 | 1 | — |
| Latch | 0 | — |

逐模块 (gwsynthesis/*_syn_rsc.xml)：

| 模块 | LUT | 其它 |
|---|---|---|
| VP (vocab_prune_sf) | 16,690 | 1×MULTALU27X18 |
| OH (output_head_sf) | 34 | — |
| u_ras (route_asm_sf) | 70 | — |
| u_ex (sched_exec) | 551 | 1×MULTALU27X18 + 1×MULTADDALU12X12 |
| u_ctl (attn_inner_ctl_sf) | 2,957 | 4,228 FF |
| aw (attn_window) | 60 | 117 FF |
| u_rail (gemv_rail_ctl) | 11 | — |
| u_pool (sram_pool_arb) | 5 | 1×BSRAM |
| u_arr → u_lane0 | 1 | 1×MULTALU27X18 (**MAC 乘法器真在网表里**) |

`grep "swept in optimizing"` = **0** → 引擎链全部保留在位流里（2026-10-21 之前它们全被剪掉）。

## Timing (pnr/tr_content.html)

```
sys_clk 约束 = 20.000 ns (50.000 MHz, P16 板载 50M 振荡器, 无 PLL)
sys_clk 实测 Fmax = 57.736 MHz   (logic level 21)
Setup 违例端点 = 0    TNS = 0
Hold  违例端点 = 0
```

## Pin check (pnr/rpt.txt) — 全对

```
sys_clk = P16   rst_n = K16
led[0]=J14 led[1]=R26 led[2]=L20 led[3]=M25 led[4]=N21 led[5]=N23
uart_rx = U16 (40P pin_header[0])   uart_tx = V16 (40P pin_header[1])
```

## Bitstream

```
fs = F:\sram\sram\out\138k_pro\decode_top\board_decode_top_r2p3\impl\pnr\board_decode_top.fs
     (33.3MB, 2026-10-22 09:51; PnR elapsed 794s)
```

## 烧录（PC 执行）

```powershell
D:\Gowin\Gowin_V1.9.12.03_x64\Programmer\bin\programmer_cli.exe `
  --cable-index 1 -d GW5AST-138B --frequency 15MHz -r 2 `
  --fsFile F:\sram\sram\out\138k_pro\decode_top\board_decode_top_r2p3\impl\pnr\board_decode_top.fs
```

⚠️ `--frequency` **没有 8MHz 这个值**（合法值 2.5/2/15/10/1.5/1.1/0.9/0.75/0.5/0.3/0.4/0.1/0.02MHz）；
传 8 会被忽略、实际跑 15MHz。**15MHz 实测 30s 烧完**（退出码 0）。
烧录前确认无残留 `programmer.exe`（GUI 占 USB 调试器）；**烧完别断电**（SRAM 易失）。
烧录操作坑（进度条截断/15MHz 中断需断电复位/极性自检）见 `notes/PC-BURN-M25.md`。

## 板验判活（期望）

> **LED 极性：本板 LED 共阳 → 逻辑 0 才点亮**（`periph_smoke.cst` 注释「共阳低亮」；
> 仓库已烧通过的 `board_top.v` / `board_freq800_sentry.v` 一律写 `~signal`）。
> **极性自检口诀：按住复位不放 → 六个信号全清 0 → 六盏灯应全亮**；全灭=极性反了。
> 本文件 2026-10-21 首烧就是极性接反（"条件成立=灯灭"），读数与实际完全相反，
> 差点误判成"引擎挂死"；复位键自检 + 仓库既有板级顶层的接法把它钉死。

| LED | 引脚 | 期望（极性修正后） | 证明什么 | 何时成立 |
|---|---|---|---|---|
| LED0 | J14 | 慢闪 | 独立计数器（与核心无关） | 上电即动 |
| LED1 | R26 | **弱（暗闪）** | busy 高电平只占 ~8%（跑帧那几百拍 / 2048 拍周期），24Hz 重复 → 眼睛看成暗闪 | 上电即动 |
| LED2 | L20 | **灭**（帧沿瞬亮，抓不到） | done_state 常态 0（只在 a_words==128 或 done_ir 那 1 拍为 1）→ 驱动 1 → 灭 | — |
| LED3 | M25 | **常亮** | **解码帧闭环 GOOD**（连续两帧 +128 词且内容流活跃） | ≈3200 拍 ≈ 64ms |
| LED4 | N21 | **常亮** | **引擎 attn 段出非零内积**（窗灌+读回+内积分块+乘累加链全活） | ≈1460 拍 ≈ 29ms |
| LED5 | N23 | **常亮** | **引擎爬满 4 层**（SELFREL 自释放后多层循环成立；每层含 GEMM 段 → rail 链同时在网表里） | ≈8200 拍 ≈ 164ms |

**2026-10-21 真机实测（极性修正版，15MHz 烧录后）**：
`LED0 闪 / LED1 弱 / LED2 灭 / LED3 常亮 / LED4 常亮 / LED5 常亮`
→ 与上表逐条一致，**六项全过**。注意 LED2 常态是"灭"（不是故障），LED1 常态是"弱"（不是故障）。

LED4/LED5 是**板级锁存 PASS 灯**（见过一次就常亮）：板上会话周期只有 2048 拍 = 40.96µs，
且引擎每会话只活动几百拍 → 任何人类可见的闪烁都表达不出来，故用锁存灯。
（想改成"呼吸灯"要先拉长帧周期，见 docs/SIDE_QUESTS.md 侧支 #9）

## 板级实测记录（2026-10-21 首烧，极性未修正版）

首烧（15MHz，30.7s，退出码 0）读数：**LED0 闪 / LED1 常亮 / LED2 常亮 / LED3 灭 / LED4 灭 / LED5 灭**。

按错误极性（1=亮）读 → 像是"解码挂死 + 引擎没跑"；
按正确极性（0=亮）读 → good[1]=1、eng_attn_seen=1、eng_gemm_seen&eng_layers_seen=1
→ **三项 PASS 条件全部成立**。

判决性验证（用户实做）：**按住复位不放 → 六盏灯全亮；松开 → 恢复原样**。
复位期间 div/busy/done_state/good[1]/eng_* 全为 0 → 全亮 = 极性自检通过；
松开后 3/4/5 仍"灭" = 三个条件随后成立（灯灭=条件真，因为极性反了）→ 板子在正常工作。
→ 结论：**板子全过**，首烧的问题只在 LED 语义不可读，已于同版修正（`~signal`）并重烧。

## 板级实测记录（2026-10-22，加 UART 版，极性已修正）

烧录：15MHz，28.8s，退出码 0，`Finished.`；烧后复扫器件仍应答（ID 0x0001081B）✓

读数：**LED0 闪 / LED1 弱 / LED2 灭 / LED3 常亮 / LED4 常亮 / LED5 常亮**

| LED | 读数 | 判读 |
|---|---|---|
| LED0 J14 | 闪 | 心跳 ✓ |
| LED1 R26 | 弱 | busy ~8% 占空 @24Hz → 暗闪 ✓（不是故障） |
| LED2 L20 | 灭 | done_state 常态 0 → 驱动 1 → 灭 ✓（帧沿瞬亮抓不到） |
| LED3 M25 | 常亮 | 解码帧闭环 GOOD ✓ |
| LED4 N21 | 常亮 | attn 内积出非零 ✓ |
| LED5 N23 | 常亮 | 引擎爬满 4 层 ✓ |

**六项全过**。加 UART 后灯态与上一版一致 → UART 没破坏解码/引擎链路
（PnR 侧印证：21,768 LUT+ALU = 15.8%，Fmax 57.736MHz 仍比 50MHz 约束高 15%）。



## 这一轮修的五件事（每件都有独立证据）

1. **vocab_prune_sf 资源爆炸** → 整包综合撞 `RP0006`（533,752 LUT > 138,240）。
   定位：Gowin 官方逐模块资源树（`_syn_rsc.xml`）+ 子树单独综合
   （head 子树单独 = 532,659 LUT，单它一个就超器件 3.86×）。
   修法：`fk` 的 1024 份 34bit 乘加+取模 → 代数等价改写
   `((7a+17x) mod 23) == (((7a mod 23)+(17x mod 23)) mod 23)` → 1 份 19bit 取模 + 常量表。
   证据：穷举 a∈0..65535 × x∈0..1023（6710 万组）0 差异；iverilog lockstep A/B 4/4 IDENTICAL。
   效果：533,752 → 21,768 LUT+ALU（整包）。
2. **顶层端口 `clk` → `sys_clk`**：全仓三个板级顶层都用 `sys_clk`，只有这个例外 →
   CST/SDC 找不到对象（`CT1135` ×50 条），PnR 根本跑不起来。
3. **`decode_auto_core` 三根悬空线**（Gowin `EX2565` 早就在报，之前被 sweep 掩盖）：
   a. `attn_window.words_written/words_read` 没接 → `sched_exec.a_ww/a_wr` 恒 Z
   b. `attn_inner_ctl_sf.blocks_done` 没接 → `sched_exec.c_blocks` 恒 Z（隔了个没人驱动的 `ex_c_blocks`）
   c. `sched_exec.slice_rdata` 没接 → GEMM 段读 X
   后果：attn 段永远收不了口 → 引擎卡死 S_ATEND → 后续会话的 go 脉冲被忽略（只跑一次）。
   修后实测（iverilog 探针 `sim/devtests/engine_probe_tb.v`）：
   `attn_done=4 / gemm_done=4 / layers_done=4 / ctl_blocks=160 / ctl_rows=1280 /
    aw.words_written=2560 / rail_frames=20 / arr_acc_out=ade4`（真实非零内积）。
4. **关键路径 `sched_exec.se_in` 的 32bit `%254`** → 98 级 / 74.7ns / Fmax 13.369MHz。
   收窄为 16bit 常数除法（实参域和 ≤ 57579 < 2^16）→ Fmax 57.736MHz。
   证据：穷举 32768 组合 0 差异；decode_auto 矩阵 8 行代表全绿。
5. **侧支#8 引擎自释放**：`released`（喂 `sched_exec.layer_sync` 的 wb_flow 释放计数）
   在板级从未被赋值、恒 0 → 引擎跑完第 1 层就卡在 S_REL。
   修法：`decode_auto_core` 加参数 `SELFREL`（产品默认 0 → 行为不变），
   板级实例化时置 1，用"引擎自己的层进度+1"当释放源。
   修后：引擎每会话爬满 4 层再回 S_IDLE，`a_go` 从 1 个脉冲变 20 个/20000 拍。

## 回归状态（iverilog 12.0, WSL）

| TB | 结果 |
|---|---|
| core_selftest_tb | PASS（内容哈希 `0104bef0` 两次同 seed 一致 → 解码数据面未动） |
| core_smoke_tb | PASS |
| board_good_tb | PASS（`led=111000`：led3 GOOD + led4 attn + led5 4 层） |
| core_stress_tb | FAIL = **DC01 既有缺陷**（信用停摆窗下 assembler 切片相位错位，前 71 词一致 / 后 48 词 +0x20 偏移）。已用 HEAD 版 `decode_auto_core.v` 对照：两版输出**逐字节相同** → 与本次改动无关 |
| decode_auto 矩阵 | 8 行代表全绿（6 PASS + 2 CAUGHT） |
| lockstep A/B | IDENTICAL 4/4（router_sel / route_asm / attn_inner_ctl / head_vprune） |

## 诚实边界（这版位流证明不了什么）

1. **slice LUT 未预灌**：顶层 `wr_en=0`，词表切片内存上电为 0（Gowin FF 默认 init 0），
   故 `out_data` 全 0，帧哈希是"零数据"的哈希。
   → LED3 只证明"帧节奏(+128词/帧) + 输出流在动"，**不证明真词表数据正确**。
   真数据需 PC 侧改 `wr_data` 预灌（`notes/PC-BURN-M25.md` 待办第 6 项）。
2. **attn 内积的权重是伪随机数**（`sched_exec.wordval` 生成），q 模板是常量
   `64'h0123_4567_89AB_CDEF`（给非零 q 是为了让乘法链不被综合器折成常量，
   否则 LED4 恒灭且 MAC 不在网表里）。
   → LED4 证明"乘法链在算且出非零"，**不证明算的是对的权重**。
3. **引擎的层释放是替身**：SELFREL=1 用"自己的层进度+1"当释放源，板级无 wb_flow 消费者
   → LED5 证明"多层循环成立"，不代表真实写回链路成立。
4. **gclk0 域未被 STA 覆盖**：MAC 的门控时钟 `U/u_arr/gclk0` 报
   "No timing paths to get frequency"，该域到 sys_clk 的采样路径无完整 STA。
   实际 `gclk0 = sys_clk & latch`（同沿），采样边沿对齐，风险低但报告上无覆盖。
5. **DC01**（见上，既有缺陷，板级 `STRESS=0` 不触发）。

## UART 通道（2026-10-21 新增，可与 PC 对话）

板载那根 "USB JTAG&UART" 线的 **UART 侧接的是 AE350 RISC-V 硬核自己的 UART**
（SOM 引脚 N16/P15，网名 FPGA_TXD/RXD）—— 那是 **CPU 专用脚**（Gowin 报
`PR2017: the location is a dedicated pin (CPU)`），所以 **FPGA 用户逻辑接不进那个 COM 口**。

→ 用户逻辑的 UART 走 **40P 排针**（引脚源：`D:\gowin\TANG_MEGA-138K-Pro-Dock\09_Misc\
tang_mega_138k-pro_pins.cst` 的 `pin_header[0..37]`）：

| 信号 | FPGA 封装脚 | 40P 排针 | 接线 |
|---|---|---|---|
| `uart_tx` | **V16** | pin_header[1] | → USB-TTL 转接头的 **RX** |
| `uart_rx` | **U16** | pin_header[0] | ← USB-TTL 转接头的 **TX** |
| GND | — | 排针 GND | ↔ 转接头 GND |

（两颗相邻、3.3V、无其它功能占用；同表 JTAG 专用脚 H12/H10/J10/H11 本设计不占用。）

**115200 8N1**，每帧吐一行：

```
F=<帧号> W=<词量> H=<帧哈希> A=<attn内积> L=<引擎层数> R=<rail帧> C=<末次命令>\n
```

**命令**（PC → 板子，1 字节 = 1 条）：
- 低 4 位 → 覆盖 `xext`（候选窗半径 0..15）→ 立刻改变 head 路径的候选窗 → 下一行的
  `H`（帧哈希）与 `L` 会跟着变 → **能亲眼看到"改一个参数 → 引擎行为改变"**
- bit4 → 立刻手动触发一帧（不等 2048 拍的节拍）
- 收到命令后 `C` 字段回显该字节

**PC 侧工具**（不依赖 pyserial，用 .NET 自带串口）：
```powershell
powershell -File tools\board_uart_read.ps1              # 自动扫 COM 口并打印行
powershell -File tools\board_uart_read.ps1 -Send 0x12   # 发命令: 低4位=2(xext), bit4=手动触发一帧
```
（另有 `tools/board_uart_cli.py`，需 pyserial。）

**验证**（两个 TB，均 PASS）：
- `sim/devtests/uart_loop_tb.v`：TX→RX 直接环回，8 字节全对
- `sim/devtests/board_uart_tb.v`：整板行格式 + 命令通路（xext 被命令覆盖 ✓、C 字段回显 ✓）

**UART 实现里踩过的坑（均已修）**：
1. TX 少发一位（`bidx==7` 直接发停止位 → bit7 从未发出）
2. 字节间无空隙 → 接收端还蹲在 S_STOP 时下一个起始沿就到了 → **整字节错一位**
   → 加 `S_END` 空闲位（字节间高电平 ≥2 位时间）
3. LSB-first 装配方向搞反（应右移、新位进最高位）
4. 十六进制位序反了（应高位在前）→ 改用 4bit 轮转
5. 字段末值算错（把"字段数 7"当"末位下标 7"→ 多发一个野字段）
6. 仿真里 slice LUT 未预灌 → 帧哈希整条是 X → 报告器加 `===` 自比较把 X 归零
   （硅上无 X，此分支恒不生效）


## 已知编码坑（本轮踩到）

- Gowin 的 tcl 解释器按**系统编码(GBK)**读源文件 → `puts` 写出的中文是**混合字节**
  （同一行里有的字对有的字坏）。故 `decode_top_result.txt` 改为**纯 ASCII**，
  中文叙述放本文件。
- PowerShell 5.1 读**无 BOM 的 UTF-8 `.ps1`** 按 GBK 解码 → 控制台回显乱码
  （`launch_dtop_synth.ps1` 已加 UTF-8 BOM，与仓库里 `watch_pnr.ps1` 一致）。
  文件内容本身无碍。
