# rtl/ — 数字硬件学习（线二）

北极星：让 LLM 权重住进内存设备（CXL 类内存侧权重层）。

造 DDR5/CXL 物理层不是个人能做的，但**硬件技能可以零成本学**：
RTL（Verilog）用 iverilog + vvp 仿真，手机 Termux 就能跑，不需要任何板子。

## 工具（Termux，已装）

```bash
iverilog -o tb counter.v counter_tb.v   # 编译（iverilog = RTL 的"编译器"）
vvp tb                                  # 运行仿真（vvp = RTL 的"模拟器"）
```

仿真输出是文本（$display/$monitor），无图形界面也能验证功能正确性。

## 学习路径

1. 组合逻辑（门、加法器）—— 数据不跨时钟
2. 时序逻辑（触发器）—— 数据跨时钟，**这是 RTL 和普通程序的分水岭**
3. 计数器 / 移位寄存器 —— `01_counter`（同步 4 位计数器）✅
4. 有限状态机（FSM）—— `02_lru`（2 路 LRU：替换策略的硬件种子）✅
5. 简单缓存 / 队列 —— `03_cache`（4 路 LRU + 命中计数，你的 k3_cache 微型版）✅
   - 状态机硬核规范：同一个 always 块里 `=` 算临时量、`<=` 更新状态
   - 三课连踩同一个竞态：**输入必须在两个时钟沿之间摆好**，不能和 posedge 落同一拍
   - 震荡(thrashing)：工作集 0A-0E 塞 4 路 → LRU 持续驱逐即将用到的块 → K3 的 36.24% 微型版
6. 内存侧调度器的 RTL 模型 —— `06_sched`（三级预取调度器 L0/L1/L1.5）✅

## 已做（可回到任意一课）

- `01_counter` —— 同步 4 位计数器（时序逻辑入门）✅
- `02_lru` —— 2 路 LRU 替换（FSM + 计数器）✅
  - 落盘（2026-08-16）：`lru2.v` + `lru2_tb.v`，iverilog 仿真 ALL PASS
  - 真 LRU 语义：命中某路→该路 MRU，lru_way 指针转向另一路；miss 替换指针路
  - 竞态教训（重演）：沿上若边更新状态边由组合输出读新状态，会"自写自读"→
    hit/way 必须在沿上用**旧标签**判定并寄存，再更新 tag
- `03_cache` —— 4路组相联 LRU 缓存 + 命中计数；K3 trace 复现 36% 瓶颈 ✅
  - 落盘（2026-08-16）：`cache4.v`（参数化 SETS/WAYS）+ `cache4_tb.v`（单测），iverilog ALL PASS
  - 4 路 × 4 组 = 16 槽；rank 模型真 LRU（每组 rank 0=MRU..3=LRU，命中归零、
    其他下沉 +1saturate；miss 替换 rank==WAYS-1 路）
  - hits/misses 计数输出 → 就是 §5.7 校准 L0-SRAM 决策规则用的统计量
  - **K3 trace 复现（本课承诺兑现）**：
    - `gen_k3_trace.py`：按白皮书 §5.7 结构生成路由 trace（92 层 × 896 专家、
      每 run 工作集 ~87 专家 / ~136 请求，复用因子 ~1.57）；同 seed 增补
      `k3_trace_runs.txt`（每行 `start length`，run 边界元数据，供周期保留重放，
      trace 本体逐字节不变）
    - `lru_ref.py`：Python 大容量 LRU 参考重放 → **容量 ≥96 后命中率平台 36.4~37%**，
      与白皮书 36.3% 上限、kimi-k3 真机 8~64GB 恒 36.24% 精确吻合
    - `k3_trace_tb.v`：RTL cache4（参数化容量）重放同一 trace：
      | 容量 | RTL(组相联) | ref(全相联) |
      |------|------------|------------|
      | 64   | 29.75%     | 30.97%     |
      | 128  | 34.94%     | 36.43%     |
      | 512  | 36.68%     | 36.68%     |
    - 结论：**36% 命中瓶颈是结构性的**（批复用因子 1.57 的天花板），不是缓存替换
      策略的错——容量翻 8 倍命中率只 +1.9pp；组相联 RTL 与全相联 ref 的差距
      (0.4~1.5pp) 是 set 冲突代价，高容量时收敛
    - **oracle k=1 预取上界（本小节）**：cache4 加 `pf_req`/`pf_tag` 预取通路
      + `pf_installs`/`pf_hits` 计数（预取装入数 / 预取救活的命中数）：
      | 容量 | LRU 基线 | oracle k=1 | 预取可买空间 |
      |------|---------|-----------|------------|
      | 16   | 16.17%  | 100.00%   | 84pp       |
      | 128  | 34.94%  | 100.00%   | 65pp       |
      - oracle k=1（每拍预取下一请求）在任何容量都 100%——trace 是批内局部复用
        结构，k=1 先知在访问前一拍装入工作集专家，缓存 ≥1 槽即全命中
      - **这是 §5.1 "oracle all-hit" 型性能预算上界，不是可达目标**：它精确量化
        "预取可买的空间"，与白皮书 §1"命中率由路由统计决定、预取只隐藏延迟"一致
      - 验证：oracle 关掉时回归到基线 34.94%（预取通路对纯 LRU 零干扰）
  - 时序协议：请求沿前 ≥3ns 摆好（#3），沿后 #3 采样；沿前 #1 会采样旧值
  - 踩坑（本次）：TB 里 tag 字面量写成 `10'h400`/`10'h500`，其值(0x400=1024)
    超出 10 位被 iverilog 静默截断成 0 → 标签全 0 假命中。教训：字面量位宽
    要与目标匹配，调试先验证字面量本身
- `04_dequant` → 已并入 `05_gemv`（`dequant.v` / `dequant_tb.v` / `gen_dequant_tb.c`，
  归档见 `04_dequant/README.md`）
  - MXFP4 去量化（OCP MX 标准）：E2M1 值集全为 `1.0b/1.1b × 2^e`，所以去量化是
    `符号 + 纯整数指数加法 + 1-bit 尾数查表`，零浮点乘法器
  - 北极星需要的第一个内存侧功能：权重字节在内存里是 E2M1×E8M0，
    必须还原成 fp32 才能参与乘累加
  - 关键洞察：E2M1 值集全为 `1.0b/1.1b × 2^e`，所以去量化是
    `符号 + 纯整数指数加法 + 1-bit 尾数查表`，零浮点乘法器
  - 验证：`gen_hex.py` 从真实 checkpoint 权重生成 fixture，TB 逐位比对
    229,376 个元素 0 失配（`ALL PASS`）
  - 可综合验证（2026-08-16）：yosys `synth` 0 问题 → 68 个标准单元
    （AND/NAND/OR/XOR/MUX）；综合出的网表跑同一批 22.9 万元素
    后综合仿真同样 `ALL PASS`（`yosys -p "read_verilog -sv dequant.v;
    synth; write_verilog synth_dequant.v"` → 再和原 TB 一起跑 vvp）
  - 教训：`packed` 是 SystemVerilog 保留字，不能当信号名；
    有符号数和无符号数相加必须显式 `$signed`，否则 `-1` 变 `+15`
  - **边界 bug 补获（回归时发现，2026-08-16）**：早期"0 失配"只覆盖真实 checkpoint
    的 scale（~0x7E-0x85），漏了极端 E8M0：`sb<2` 时乘积下溢成次正规（RTL 误给
    0/inf）、`sb>253` 时溢出应 ±Inf（RTL 误给 ±0/NaN）、次正规 sign 拼接位宽错误。
    补 `dequant_tb.v`（C 参考生成 256 字节码 × 32 scale 全边界 16384 元素逐位比对）
    抓到 512 失配 → 修 expf 加宽 10bit signed + 次正规尾数右移 + sign 8bit 拼位
    → 全边界 ALL PASS，纳入 check.sh [0/6] 回归门
- `05_gemv` —— GEMV 内存侧数字外围：fp32 加法器 + 跨组累加 MAC ✅
  - `f32_add.v`：教科书式单精度加法器（对齐→加/减→规格化→RN-even 舍入→
    溢出/次正规/±inf/±0/NaN），逐位对照 C golden 的 `pim_mxfp4_periph_acc`
  - `periph_mac.v`：跨组 fp32 顺序累加 `y[r]=Σ_g q[r][g]×2^(sb-127)`，
    `periph_scale.v` 做精确 2 幂乘（指数加法，零乘法的关键设计）
  - 验证：C 语料 20022 例 + 独立 Python 参考（精确整数运算）百万例
    （`indep_add.py`：定向边界矩阵 + 次正规/舍入/进位/对消密集随机）
    + `gen_mac_edge.c` 边界 fixture（scale==255 跳过、±inf/NaN 累加、
    次正规乘积、+0/-0、对消、累加溢出）——两套独立实现交叉对敲
    ——各抓住对方一个真 bug：
    - RTL f32_add：次正规负结果符号被 `{cneg,8'd0,m_sub}` 33 位拼接截断
      （C 语料随机的双次正规异号组合命中概率≈0，覆盖缺口）→ 改 `m_sub[22:0]`
    - Python 参考：`-inf + -inf` 漏了符号位，返回 `+inf`
    - RTL periph_scale：次正规输入未归一化，套正规输出格式 `{s,norm_e,qm}`
      错值；能产生 x 的 R>24 时 g/r/stk 越界取位 → 加归一化级联 + 越界保护
  - 感想：扩展验证马上抓到第二、第三个真 bug（periph_scale 归一化/越界），
    证实"C golden 全过"对次正规/极端 scale 覆盖不足；去相关随机测试值得做
  - 教训：跨组累加唯一舍入点是加法器，一次舍入语义要盯死;
    TB 竞态：输入必须在时钟沿之后 `#1` 再改，不能和 posedge 落同一拍
  - 流片视角：C golden 比对是必要非充分——去相关独立参考 + 定向分支矩阵
    才能抓"两实现共享的语义误解"型错误
  - 性能打磨（2026-08-16）：把模块从"正确"推到"面积能打"
    - 结构优化 ① `periph_mac` 去掉一路 `f32_add`：`0.0f + term ≡ term`
      （IEEE RN 恒等，唯一特例 `-0 → +0`），一个 32-bit 比较器顶掉整颗加法器
    - 结构优化 ② 规格化段从 27 级 `if` 级联 × 每级一次完整移位，改为
      **前导零计数（优先级编码→5-bit nz）+ 单次桶形移位**（f32_add 与
      periph_scale 同改）——面积与深度都从线性降到对数
    - 代价：逻辑等价性由全套回归兜底（C 20022 / fixture 64 / edge 48 /
      独立 Python 百万级，5/5 ALL PASS，100 万级仍逐位零失配）
    - 收益：yosys flatten 综合后 **6596 → 3030 cells（-54%），FF 数不变**，
      MUX 660→467；桶移前的 27 级移位级联正是旧网表 4 倍冗余的出处
    - 卫生：三个 RTL 文件补 `` `timescale 1ns/1ps ``，`iverilog -Wall` 0 警告
- `06_sched` —— 三级预取调度器 RTL 模型 ✅
  - 落盘（2026-08-16）：`sched3.v`（L0 pinned 静态热表 4 槽 + L1 LRU 5 槽 +
    L1.5 环形预取池 4 槽，全阻塞赋值规避 03 踩过的 iverilog 数组 bug）
    + `selfsched_tb.v`（读 `../03_cache/k3_trace.txt` 重放 100,919 请求 + oracle k=1 预取）
  - K3 trace 分账（13 槽极小预算）：三级命中 9.47% = **L0 0.1% + L1 4.6% + L1.5 4.8%**；
    关预取对照 6.22%（≈ cap5 纯 LRU 6.17%）→ **预取贡献 +3.25pp**
  - **L0 全局热仅 0.1%**（top4 专家全局频次仅 17/16 次=跨 run 无稳定性）
    → RTL 实证 §5.7"per-layer 架构 SRAM 应跳过"；预取在极小预算下也净加命中
  - 诚实边界：13 槽命中 9.47% 低于 ref cap13 纯 LRU 15.02%（预取池挤占 LRU
    有效容量的结构损失，极小预算下的预期折衷）
  - 已纳入 `05_gemv/check.sh [6/7]` 回归门
  - **可综合性检查（2026-08-16）**：`yosys synth` 消化建模版（`memory` 自动展开数组
    → 寄存器阵列），无报错 → 10283 cells / 605 FF（14 "槽"全 CAM 展开的全网表开销）。
    结论：**数据平面真实现不会被这么写**——槽数组应做索引哈希（真 CAM 或 SRAM+tag），
    且计数/统计端口该裁掉；本综合是"结构可综合"下限证据，不是实现模板

## TinyTapeout 提交形态（2026-08-16）

- **目标**：把 periph_mac 整理成 SkyWater 130nm 可提交设计（`tt_um_periph_mac.v`，
  TTSKY26c 截止 2026-09-07；1 tile ≈ 1000 门量级）
- **核心矛盾**：periph_mac 的 FSM 在 go 之后 RUN 期间每周期消费一个新 (q,scale)，
  外部串行字节装载无法与累加节奏同步 → 演示改用**内嵌 case 表格 + 行控制器**
  （NGRP=8，3 行：sel0 全跳过→+0；sel1 ±1.0 交替→对消；sel2 混合+次正规→非零）
- **接口**：ui_in[0]=run 上升沿播一行；ui_in[2:1]=行选择；uo_out[3:0]=acc nibble
  轮转、[4]=done、[5]=运行中、[7:6]=组计数
- **控制器时序**（关键）：run 上升沿把 row_active 置 1、row_g 置 1（go 拍读组 0，
  首个 RUN 周期读组 1），RUN 期间 row_g 每拍递增，done 清 row_active；
  `go = run && !run_pp` 保证单拍脉冲（电平 go 会让 FSM 重复启动）
- **对拍 TB**（tt_wrap_tb）：wrapper 内 periph_mac(accB) vs 直连参考(accA) 全 32 位
  逐位；3 行 8 组 ALL PASS
- **面积**：tt_um_periph_mac 整包 yosys 综合 **1111 cells / 57 FF**（内嵌表格在
  综合后成常量供电，periph_scale 乘法器被优化掉）——落 1 tile 预算内有余量
- **调试债**：① 表格组号落后一拍→row_g 在 go 沿即置 1；② 电平 go 重复启动；
  ③ 参考驱动 go 必须单拍（与 fixup 同训——输入禁与 posedge 落同一拍）
- 待办：TT 提交清单（pin 规划、GDS 预检、日期截止）

## 对照表（你已经会的 → 硬件对应）

| 软件概念 | RTL 对应 |
|---|---|
| 变量赋值 `x = y + 1` | 组合逻辑（wire / assign） |
| 有状态（循环、函数调用） | 寄存器（reg + 时钟） |
| 时钟（同步推进） | `always @(posedge clk)` |
| 断言/测试 | testbench + $display |
| 编译 | iverilog 综合出电路 |

每个练习带一个自检 testbench，跑出 `ALL PASS` 才算过。
