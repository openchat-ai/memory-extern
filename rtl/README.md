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
   - 模板：组合逻辑算 next_state + 寄存器在边沿锁存
   - 教训：复位释放时要清掉挂着的输入，否则立刻被消费
5. 简单缓存 / 队列 —— 下一课：4 路 LRU + 命中计数器，长成真缓存
6. 内存侧调度器的 RTL 模型 —— 北极星的软件层

## 对照表（你已经会的 → 硬件对应）

| 软件概念 | RTL 对应 |
|---|---|
| 变量赋值 `x = y + 1` | 组合逻辑（wire / assign） |
| 有状态（循环、函数调用） | 寄存器（reg + 时钟） |
| 时钟（同步推进） | `always @(posedge clk)` |
| 断言/测试 | testbench + $display |
| 编译 | iverilog 综合出电路 |

每个练习带一个自检 testbench，跑出 `ALL PASS` 才算过。
