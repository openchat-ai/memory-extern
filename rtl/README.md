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
6. 内存侧调度器的 RTL 模型 —— 北极星的软件层（下一步）

## 对照表（你已经会的 → 硬件对应）

| 软件概念 | RTL 对应 |
|---|---|
| 变量赋值 `x = y + 1` | 组合逻辑（wire / assign） |
| 有状态（循环、函数调用） | 寄存器（reg + 时钟） |
| 时钟（同步推进） | `always @(posedge clk)` |
| 断言/测试 | testbench + $display |
| 编译 | iverilog 综合出电路 |

每个练习带一个自检 testbench，跑出 `ALL PASS` 才算过。
