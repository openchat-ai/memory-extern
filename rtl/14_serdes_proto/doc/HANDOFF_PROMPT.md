# HANDOFF — 14_serdes_proto 项目延续 prompt

把下面整段（从 `# 任务` 到 `# 终点`）粘贴进一个新的 AI 会话即可无缝接手。复制时保留全部待办原文，不要改写。

---

# 任务

你是这个仓库的新会话助手，接手 `/data/data/com.termux/files/home/sram/rtl/14_serdes_proto/` 的 RTL 硬件项目。你先只读，不要改任何文件；输出一份"我理解了，计划如下"再等确认。

## 项目一句话
"通用 SerDes 协议抽象层"：从零写一套能贴在任意 SerDes/目标硬件上的协议栈（自定义裸 SerDes / PCIe / SFP+ 风格），最上层做 **GEMV 引擎 + 专家权重从 NVMe SSD 流式读取**（北极星：LLM 权重住进内存设备）。

## 硬性环境约束（必须遵守）
- 运行环境 = **Termux (aarch64, Android)**，只有 **iverilog -g2012** 能仿真。
- **没有且不装 Gowin IDE，不能跑 PnR**，没有板子的 pwrctl/lspci 真机手段。
- 真机 PnR/STA、`gw_sh build_sweep.tcl`、板子 `lspci` 只能用户自家 PC/板子执行——**你能做的只是让 RTL/仿真/tcl/文档 全部就绪**，真机动作一律由用户跑。
- 改动必须：编译过 + sim.sh 全绿 + 新增/修改的每个行为有 tb 断言。不要只加注释声称"应该对"。
- 一律先 `git status` + 读相关文件，别凭记忆改；不留调试临时文件在仓库里。

## 仓库位置与结构
- 根：`/data/data/com.termux/files/home/sram/`（git repo，分支 main，远端 origin 已配好）
- 本项目目录：`rtl/14_serdes_proto/`，含 `core/`（proto_core）、`adapter/{axis_pcie,custom_serdes,nvme,path_cache,sfp_serdes}/`、`tb/`、`doc/ARCHITECTURE.md`、`sim.sh`。
- 一键回归：`cd rtl/14_serdes_proto && ./sim.sh`，当前 **22/22 ALL GREEN**（每项有 tb，全过 exit 0）。
- 架构文档：`rtl/14_serdes_proto/doc/ARCHITECTURE.md`（§1 抽象层分层 / §11 NVMe Host 设计 / §11.5 工作量风险分解，v2 已按原理图更正过）。

## 已完成（不要重做，不要推翻）
- proto_core 纯流式内核；axis_pcie / custom_serdes / sfp_serdes 三个适配器实例；CRC/link/framer/多 lane。
- path_cache：SSD 双路径探测+统一权重流；cachectl_pipeline（探测+选通+专家LRU+GEMV）；ext4_scan_core + cache_lba_top + file2lba（文件→LBA 全链路）。
- NVMe 阶段 N1/N2/N3（nvme_host FSM + 行为桩），**N6 对接桥 `nvme_bridge.v`**（应用层块请求<->nvme_host<->设备桩）——22/22 ALL GREEN。
- 138K 引擎 PnR 问题：分层归约树 + PIPE_MUL 三级流水 + 输入寄存器级，200MHz 约束可收敛，400MHz 实验 PLL 就绪。

## 已定关键结论（有依据，别重新刨坑）
1. **GW5AST-138 硬核支持 RC 和 EP 双模式**（DS981 / DS1104E 原文确认）。
2. **板载 M.2 座(B-key)只接 Q1 通用 SerDes 的 2 lane**（`Q1_DAT2/Q1_DAT3` + `Q1_REFCLK0`），**不在 PCIe 硬核上**；**PCIe 硬核只到板子自己 PCIe 金手指**（Q0，x4）。
3. 目标形态：**T1 = FPGA 直挂 NVMe 盘为主**，但物理上 SSD 走 **M.2→PCIe x4 被动转接卡插金手指**（FPGA=RC）；**T2 = PC 居中**（SSD 在 PC M.2、FPGA 插 PC PCIe 槽当 EP）作为过渡真机验证路径，先做。
4. K3 带宽决策：引擎 200MHz≈12.8GB/s ≥ NVMe 单盘 ~2GiB/s，NVMe 不超频，真实杠杆 = PCIe 链路训练（Gen3 x4≈3.5GB/s）+ 多盘并行 + Q4 调度。
5. 三层 FIFO 语义教训（写 tb 时遵守）：缺 `timescale` 必死于 timeout；流式接口 `o_ready=0` 只停"下一次"出队，已出队字凭 `o_valid` 停留，背压不丢字；`done` 是单拍脉冲，等待要"基线快照 + 边沿计数"。

## 待办（按优先级，从上到下）
1. **T2→T1 PCIe 硬核真机准备（当前唯一主线）**：把"PCIe 硬核 EP（T2）/ RC（T1）"物理适配器做成可交付的 RTL + tcl + 约束 + 用户操作清单，交给用户在他 PC 的 Gowin IDE 上真机冒烟（目标 `lspci -vv` 枚举 + link training Gen3 x4）。注意 TERMUX 无 Gowin IP，这一要求你只能写到"bitstream 就绪度"（顶层骨架/约束/伪 IP 桩/tcl），真机交付以用户执行为准。
2. **build_sweep 验收**：用户 PC 上跑 `gw_sh build_sweep.tcl 200`（自动选 PLL 兜底 200/400MHz）——把"跑"作为清单里唯一用户动作，脚本本身保持就绪，别在 Termux 空跑。
3. **bridge 与 cachectl_pipeline 对接**（可选加分）：`nvme_bridge` 的块请求语义对上 `cachectl_pipeline` 的 `wt_lba/wt_valid` 落点，加回归。
4. 任何新代码沿用 sim.sh 追加 `run <name>`，调试临时文件一律放 `/data/data/com.termux/files/usr/tmp/opencode/` 不留仓。

## 提交规范
- commit message 风格参考 `git log --oneline -8`（feat/fix/docs + 一句话 + 结果数字）。
- 只 stage 本任务文件；不 push 除非用户说；`git push origin main` 仅当用户明确要求。

## 终点
任务 1 完成 = `rtl/14_serdes_proto/` 里给出: PCIe 硬核适配器顶层骨架 + 金手指/BOARD 约束 + T2/T1 两份"用户在 PC 上照做的真机清单"（含 Gowin IDE 步骤、board 引脚、REFCLK/PERST# 处理、`lspci`/`setpci` 验收命令与预期输出）。回归仍 22/22 或更多，全绿。