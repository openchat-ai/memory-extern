# HANDOFF — memory-extern 仓库延续 prompt

把下面整段（从 `# 任务` 到 `# 终点`）粘贴进一个新的 AI 会话即可无缝接手。复制时保留全部待办原文，不要改写。

---

# 任务

你是这个仓库的新会话助手，接手 `/data/data/com.termux/files/home/sram/` 的**整个仓库——它不是多个项目的堆叠，而是一个有机整体**。先只读，不改文件；输出一份"我理解了，计划如下"再等确认。

## 这个仓库是什么（一句话）
北极星是"**让 LLM 权重住进内存设备**"。仓库是一部从**研究定案 → 数字设计 → 板级接入**的连续工程：所有目录互咬合，结论跨层引用，不是并列的子项目。

## 一条主线贯穿全部目录
1. 研究层定方案：`WHITEPAPER-三级预取模型.md`、`notes/`（架构/带宽/独立栈决策）、README「线一」的**真机 trace 闭环**（K3 36% 平台定损、Qwen LRU@4GiB≈90%、真机 8GiB=0.9400、决策门 C/B=1.06x）。**结论：90% 靠"层内聚拢/预测式预取"，速度靠"驻留 + 卸载专家 GEMM"。**
2. 数字层把方案落成引擎：`rtl/01_counter`→`11_phy_complete` 逐级学习与验证；`rtl/12_fpga_proto` 是 **GEMV 引擎原型**（SIMD MAC 阵列 + 归约树 + 流水打断 PIPE_IN/PIPE_MUL，tb 全 PASS）。
3. 板级接入：`rtl/13_mega138k` 把引擎合到 138K 板（`board_top.v` + `engine_core.v` + `pcie_dma_engine.v` v0.2 权重流 FSM + 200/400MHz PLL + `build_sweep.tcl` 频率扫描）。**200MHz≈12.8GB/s ≥ NVMe 单盘 ~2GiB/s，这是带宽决策的来源。**
4. 协议层统一喂权：`rtl/14_serdes_proto` 是"**通用 SerDes 协议抽象层**"——任意物理（自定义裸 SerDes / PCIe / SFP+）→ 统一 AXI-Stream → `proto_core` → 上层 NVMe 块请求，`sim.sh` **22/22 ALL GREEN**。
- 数据流全景：`ext4_scan`/`file2lba`/`cache_lba_top`（盘上文件→LBA）→ `cachectl_pipeline`/`expert_dir`（专家 LRU）→ `nvme_bridge`（块请求）→ `nvme_host`（NVMe 命令）→ **PCIe/SerDes 物理适配器**（回到 13 的权重流）。这就是一条完整的"SSD 专家权重 → 引擎累加"链路。

## 关键跨层结论（环环相扣，别推翻）
1. **研究→设计**：带宽墙/算力墙分析得出"缓存不超频，NVMe 单盘喂不饱引擎"，所以设计要 PCIe 链路训练 + 多盘并行 + Q4 调度。
2. **数字→板级**：138K 引擎长组合路径不可达 100MHz 默认约束 → 分层归约树 + 流水打断后 200MHz 收敛；`build_sweep.tcl` 频点实验（200 签核 / 400 提速实验 / 800 预期卡死）。
3. **协议层物理结论**（DS981/DS1104E + Sipeed 原理图已确证）：
   - GW5AST-138 硬核支持 **RC+EP 双模式**；
   - 板载 **M.2 座 = Q1 通用 SerDes 2 lane**，**不在硬核上**；**硬核只到 PCIe 金手指（Q0, x4）**；
   - 目标形态：**T1 = FPGA 直挂 NVMe 盘优先**（M.2→PCIe x4 被动转接卡插金手指，FPGA=RC）；**T2 = PC 居中过渡**（SSD 在 PC M.2、FPGA 当 EP 插 PC 槽）。

## 硬性环境约束
- 手头环境 = **Termux (aarch64, Android)**：只有 iverilog -g2012 仿真 + python3 分析。
- **无 Gowin IDE、不能 PnR、无板卡**。真机 = 用户 PC/板子：`gw_sh build_sweep.tcl 200`、`build_board_top.tcl`、`lspci` 都是**用户执行**；你负责把 RTL/tcl/约束/判据/操作清单做到"用户照做即签核"。

## 仓库现状（读哪个文件确认）
- `README.md` → 全貌与两条线的真机闭环结论
- `rtl/README.md` → RTL 目录地图（01→14 递增链）
- `notes/` → architecture-decision / bandwidth-capacity-research 等决策链
- `rtl/14_serdes_proto/doc/ARCHITECTURE.md` → 协议层设计 + §11.5 工作量/风险（v2 已按原理图更正）
- `git log --oneline -15` → 最近节奏（当前在 13 PnR 验收 + 14 NVMe 桥）

## 待办（按优先级）
1. **13 频点签核（当前主战场）**：用户在 PC `gw_sh build_sweep.tcl 200` → 判读收敛 / WNS<0 / 卡60% 三结果；你补判据模板 + `build_board_top.tcl` 综合冒烟清单。
2. **三方汇合（13↔14）**：`pcie_dma_engine`（FPGA 权重流）↔ `nvme_bridge`（块请求）↔ `cachectl_pipeline`（wt_lba 落点）语义对上，加回归（仿真桩粒度自己定）。
3. **14 PCIe 硬核真机准备**：EP(T2)/RC(T1) 适配器 = 顶层骨架 + 金手指约束 + 用户照做的 Gowin IDE 清单（`lspci -vv` 目标 Gen3 x4）。Termux 无 Gowin IP，只能到"bitstream 就绪度"。
4. 新代码沿用各支线回归；14 追加 `sim.sh run`；12/13 按各自 tb 单跑。
5. 调试临时文件一律 `/data/data/com.termux/files/usr/tmp/opencode/`。

## 提交规范
- message 风格参考 `git log --oneline -8`；只 stage 本任务文件；`master` 分支不动；push 仅当用户说。

## 终点
13 签核判据就绪 + 三方对接点清晰 + 14 PCIe 骨架/清单就绪，编译全过、14 回归 22/22 或更多全绿，并给出用户 PC/板子上的完整验收步骤与预期数值。