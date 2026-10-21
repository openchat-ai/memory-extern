# board_decode_top — 板级整包 PnR 结果 (decode 闭环 + 引擎判活, 可上硅)

> 机器读字段见同目录 `decode_top_result.txt` (纯 ASCII, 由 build_decode_top.tcl 写)。
> 本文件是人写的叙述版 (UTF-8)。最后更新: 2026-10-21 15:20。

```
mode = all   route_option = 2   place_option = 3   max_fanout = 100
elapsed_s = 809   status = DONE
```

## Resources (pnr/rpt.txt)

| 项 | 值 | 占器件 138,240 |
|---|---|---|
| LUT | 21,423 | 15.5% |
| ALU | 461 | — |
| LUT+ALU 合计 | **21,884** | **15.8%** |
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
sys_clk 实测 Fmax = 66.596 MHz   (logic level 19)
Setup 违例端点 = 0    TNS = 0
Hold  违例端点 = 0
```

## Pin check (pnr/rpt.txt) — 全对

```
sys_clk = P16   rst_n = K16
led[0]=J14  led[1]=R26  led[2]=L20  led[3]=M25  led[4]=N21  led[5]=N23
```

## Bitstream

```
fs = F:\sram\sram\out\138k_pro\decode_top\board_decode_top_r2p3\impl\pnr\board_decode_top.fs
     (33.3MB, 2026-10-21 15:20)
```

## 烧录（PC 执行；8MHz 稳，15MHz 曾 20% 失败）

```powershell
D:\Gowin\Gowin_V1.9.12.03_x64\Programmer\bin\programmer_cli.exe `
  --cable-index 1 -d GW5AST-138B --frequency 8 -r 2 `
  --fsFile F:\sram\sram\out\138k_pro\decode_top\board_decode_top_r2p3\impl\pnr\board_decode_top.fs
```

烧前确认没有残留 `programmer.exe` 占着 USB 调试器。SRAM 易失，断电即失。

## 板验判活（期望）

| LED | 引脚 | 期望 | 证明什么 | 何时亮 |
|---|---|---|---|---|
| LED0 | J14 | ~1Hz 心跳 | 独立计数器（与核心无关） | 上电即亮 |
| LED1 | R26 | busy 频闪 | route_asm 在吐流 | 上电即动 |
| LED2 | L20 | 帧内 done 高 | 帧节拍 | 上电即动 |
| LED3 | M25 | 数帧后恒亮 | **解码帧闭环 GOOD**（连续两帧 +128 词且内容流活跃） | ~3200 拍 |
| LED4 | N21 | 恒亮 | **引擎 attn 段出非零内积**（窗灌+读回+内积分块+乘累加链全活） | ~1460 拍 |
| LED5 | N23 | 恒亮 | **引擎爬满 4 层**（SELFREL 自释放后多层循环成立；每层含 GEMM 段 → rail 链同时在网表里） | ~8200 拍 |

LED4/LED5 是**板级锁存 PASS 灯**（见过一次就常亮）：板上会话周期只有 2048 拍 = 40.96µs，
且引擎每会话只活动几百拍 → 任何人类可见的闪烁都表达不出来，故用锁存灯。
（想改成"呼吸灯"要先拉长帧周期，见 docs/SIDE_QUESTS.md 侧支 #9）

## 这一轮修的五件事（每件都有独立证据）

1. **vocab_prune_sf 资源爆炸** → 整包综合撞 `RP0006`（533,752 LUT > 138,240）。
   定位：Gowin 官方逐模块资源树（`_syn_rsc.xml`）+ 子树单独综合
   （head 子树单独 = 532,659 LUT，单它一个就超器件 3.86×）。
   修法：`fk` 的 1024 份 34bit 乘加+取模 → 代数等价改写
   `((7a+17x) mod 23) == (((7a mod 23)+(17x mod 23)) mod 23)` → 1 份 19bit 取模 + 常量表。
   证据：穷举 a∈0..65535 × x∈0..1023（6710 万组）0 差异；iverilog lockstep A/B 4/4 IDENTICAL。
   效果：533,752 → 21,884 LUT+ALU（整包）。
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
   收窄为 16bit 常数除法（实参域和 ≤ 57579 < 2^16）→ Fmax 66.596MHz。
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

## 已知编码坑（本轮踩到）

- Gowin 的 tcl 解释器按**系统编码(GBK)**读源文件 → `puts` 写出的中文是**混合字节**
  （同一行里有的字对有的字坏）。故 `decode_top_result.txt` 改为**纯 ASCII**，
  中文叙述放本文件。
- PowerShell 5.1 读**无 BOM 的 UTF-8 `.ps1`** 按 GBK 解码 → 控制台回显乱码
  （`launch_dtop_synth.ps1` 已加 UTF-8 BOM，与仓库里 `watch_pnr.ps1` 一致）。
  文件内容本身无碍。
