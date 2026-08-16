# memory-extern

内存外挂：让 LLM 的权重住在内存里。

一个双线项目，目标是把"把大模型权重放到内存设备里"（现代形态：CXL 类内存侧权重层）这条北极星，拆成两条现在就能走的路：

## 线一 · 研究/软件：MoE 专家缓存三级调度

Kimi-K3 / DeepSeek 一类 MoE 模型推理时，专家权重是**动态路由**的——每个 token 只激活一小部分专家，但"哪些专家、何时用"是数据依赖的。这决定了任何内存侧驻留层都要回答一个问题：**该把哪些字节、何时放在近处**。

- `WHITEPAPER-三级预取模型.md` —— 预取/缓存三级的完整研究文档
  - §3.4：L0-SRAM 驻留层的决策规则（O + 全局 n50，三情形表）
  - §5.7：真实 trace 校准（结论：per-layer 架构 O≈0，SRAM 应跳过；批内复用 36.3% 与实测 36.24% LRU 闭合）
- `tools/` —— 真实 trace 决策统计（`sram_stats.py`）、B/D 档时序仿真（`sim_scheduler.py`）、trace 画像（`profile_trace.py`）
- `case-k25/`、`trace-demo/` —— K2.5 案例与 demo trace 的重放报告
- `sparkmoe-src/` —— SparkMoE 源码走读（k3_cache 等）与补丁、trace 采集方案

当前主线：**超迭代周期保留策略**（回收 Belady 25.5pt 策略盲区）、"负载均衡训练摧毁缓存友好性"分析。

## 线二 · 技能/硬件：RTL 数字硬件学习

北极星是"权重住进内存设备"。造 DDR5/CXL 物理层不是个人能做的事，但硬件技能可以零成本学：RTL（Verilog/SystemVerilog）在 Termux 上用 iverilog/verilator 仿真，手机就能跑。

- `rtl/` —— 练习仓库：从门电路到状态机、缓存、再到"内存侧调度器"的 RTL 模型

目标画像：三年后既懂 MoE 调度的软件侧、又懂 RTL 的硬件侧，去定义内存设备**该干什么**——不是造模块，而是定义模块。

## 约束

- 0 资源：手机 + Termux，不下载模型权重（现有资产：真实路由 trace、kimi-k3 fork、仿真器）
- 一切实证用现有数据，不编造

## 状态

- [x] 白皮书 §3.4 / §5.7 更新（O≈0 → SRAM 跳过判定）
- [x] 真实 trace 决策统计 + 仿真器
- [ ] 周期保留策略重放（LRU/Belady/周期 对照表）
- [ ] RTL 学习环境（iverilog 手机仿真）+ 第一个模块
- [ ] "负载均衡杀缓存"成文（K3 Quantile Balancing + DeepSeek 在线 bias 双证据）
