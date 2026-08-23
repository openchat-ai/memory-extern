# 独立推理栈（脱离 llama.cpp）

> **版本 0.1 草稿** · 2026-08-23 · 状态：方向确立，权重机开发中
> 动机：产权审计（bandwidth-capacity-research.md §6.4）指出策略内核构建在
> llama.cpp 系引擎之上是最大灰色地带。本方向将其消解——验证过的策略内核
> 第一次拥有完全属于自己的宿主。

## 一、目标

一个不依赖 llama.cpp 的独立 MoE 推理栈：
- 自有权重格式（流式友好，配合招一 NVMe 归零层）
- 自有 MoE 路由/expert 调度运行时（移植 sim_cache2 已验证的策略）
- 自有 GEMV 内核（pim/bench_q3_x86 结论：opt(f32)+4-way unroll）
- trace/预取作为一等公民而非 C++ 钩子补丁

## 二、零件清单

| 部件 | 现状 | 缺口 |
|---|---|---|
| GEMV 内核 | ✅ x86 最优实现已定（opt f32 + 4-way unroll） | NEON 对齐、查表融合 |
| 权重加载 | ⚠️ safetensors header 解析已有雏形（k3-verdict 流程） | 流式友好自定义格式 |
| MoE 路由/调度 | ✅ 策略层 Python 全部验证过 | 移植为 C |
| Attention/KV/sampling | ❌ 从零自扛 | 标准算法，工程量大但路径清晰 |
| trace/预取运行时 | ⚠️ 钩子版已在 research-cli 验证 | 升级为一等公民 |
| PCIe（远期） | ❌ 未开始 | 见 §四 |

## 三、开源依赖与致敬（standing on shoulders）

| 基座 | 授权 | 本项目用法 |
|---|---|---|
| llama.cpp / SparkMoE fork | MIT | 研究期的宿主与方法论试验场；经验将反哺独立栈 |
| Wavious wddr RTL | Apache-2.0/GPL 混合 | PHY 数字部分基座（rtl/10_phy_final）|
| Ibex (lowRISC) | Apache-2.0 | MCU 子系统 |
| verilog-pcie（计划采用） | MIT | 远期 PCIe 协议层 |
| 上游 sim_cache.py 作者 | —— | 方法论对话起点；其正确结论已定损收录 |

## 四、顺序建议

```
1. 独立模拟器/运行时（当前进行中，权重机）
2. GEMV die 内控制器（复用 mini-DFI 经验）
3. PCIe 最后：协议层抄 verilog-pcie；PHY 又是墙——
   备选=招二寄生术（宽并口方言+桥片代言），不做 Gen3+ SerDes
```

## 变更历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-08-23 | 初稿：脱离 llama.cpp 决策立项；零件盘点；依赖致敬表 |
