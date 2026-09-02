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
2. **数字→板级**：138K 引擎长组合路径不可达 100MHz 默认约束 → 分层归约树 + 流水打断后 200MHz 宣称收敛（未在真实 PnR 验证）。**实测更正（2026-09-02）**：macsplit 2×64-lane 方案暴露**网表级跨实例寄存器合并**根因（`syn_dont_touch` 已修复），修复后 Fmax=124.3MHz 真硅片冒烟 PASS。200MHz 仍死循环（Routing Phase 0 卡死），疑为 138K 布线引擎在超大面积下的收敛极限。124.3MHz 是当前工作频率基线。见 `rtl/13_mega138k/PNR-EXPERIENCE.md` + `macsplit_smoke_result.txt`。
3. **协议层物理结论**（DS981/DS1104E + Sipeed 原理图已确证）：
   - GW5AST-138 硬核支持 **RC+EP 双模式**；
   - 板载 **M.2 座 = Q1 通用 SerDes 2 lane**，**不在硬核上**；**硬核只到 PCIe 金手指（Q0, x4）**；
   - 目标形态：**T1 = FPGA 直挂 NVMe 盘优先**（M.2→PCIe x4 被动转接卡插金手指，FPGA=RC）；**T2 = PC 居中过渡**（SSD 在 PC M.2、FPGA 当 EP 插 PC 槽）。

## 硬性环境约束（2026-09-02 真硅片冒烟后更新）
- 手头环境 = **Termux (aarch64, Android)**：只有 iverilog -g2012 仿真 + python3 分析。
- **真机已就位**：Tang Mega 138K Pro Dock 到货；PC 已装 Gowin IDE，**真硅片冒烟已通过**（macsplit 124.3MHz，LED 心跳+引擎半亮）。
- **PC 实测链路（重要）**：
  - 综合/PnR：`gw_sh.exe`（D:\Gowin\Gowin_V1.9.12.03_x64\IDE\bin\）跑 tcl 脚本（`gw_sh build_macsplit_smoke.tcl`）。
  - 烧录：`programmer_cli.exe`（D:\Gowin\Gowin_V1.9.12.03_x64\Programmer\bin\），**8MHz 稳定**（15MHz 中断需断电复位）。命令：`programmer_cli.exe --cable-index 1 -d GW5AST-138B --frequency 8 -r 2 --fsFile <fs>`。
  - 注意：GUI `programmer.exe` 会独占 USB 调试器，烧录前先确认无残留进程。
  - tcl 头注释 `set_clock_group`→应为 `set_clock_groups`（复数）已修入仓。
- 我可以做的 = RTL/tcl/约束/判据/操作清单做到"用户照做即签核"；真机命令由**用户执行**，但每一步已排好，不再停留在"就绪度"。
- **结果同步协议（重要，省流量）**：用户不做文字回传，做完直接 `git commit` + `git push`。**入仓的只有 <10KB 文本**：PnR result（`*_result.txt`）+ `PNR-EXPERIENCE.md`（烧录经验/引脚速查）。**大日志/.fs 一律留 PC 本地，绝不 push**（手机流量）。我接手先 `git pull` 读这些 txt 判读，不催用户贴格式。

## 仓库现状（读哪个文件确认）
- `README.md` → 全貌与两条线的真机闭环结论
- `rtl/README.md` → RTL 目录地图（01→14 递增链）
- `rtl/13_mega138k/PNR-EXPERIENCE.md` → **PnR 全程经验 + 烧录实战（§9）+ 板载 I/O 速查（§10，含 6 LED/4 按键/WS2812 引脚）**
- `rtl/13_mega138k/macsplit_smoke_result.txt` → **真硅片冒烟报告（124.3MHz，PASS，烧录命令+LED观察）**
- `rtl/13_mega138k/diag_sweep200_deadloop.txt` → 200MHz PnR 死循环诊断（4 配置矩阵实证，被 macsplit+dontouch 修复部分解决）
- `notes/` → architecture-decision / bandwidth-capacity-research 等决策链
- `rtl/14_serdes_proto/doc/ARCHITECTURE.md` → 协议层设计 + §11.5 工作量/风险
- `git log --oneline -15` → 最近节奏（当前在 13 冒烟 PASS，待决定下一步）

## 待办（按优先级，2026-09-02 真硅片冒烟后更新）
1. ~~**13 board_top 真硅片冒烟**~~ ✅ **DONE**（2026-09-02，commit b742896）：
   - 位流 `board_top_macsplit_reg.fs`（124.3MHz，route=2/place=3/max_fanout=100）已烧 SRAM。
   - 结果：LED[0](J14) ~1Hz 心跳闪 + LED[1](R26) 引擎半亮 = **真硅片冒烟 PASS**。
   - 烧录命令：`programmer_cli.exe --cable-index 1 -d GW5AST-138B --frequency 8 -r 2 --fsFile <fs>`（8MHz 稳定；15MHz 中断需断电复位）。
   - GUI programmer.exe 会占 USB 调试器；烧录前先确认无残留进程。
   - 报告：`rtl/13_mega138k/macsplit_smoke_result.txt`。
2. **13 频点签核（当前阻塞）**：200MHz 仍死循环（Routing Phase 0 卡死），但 **124.3MHz 收敛版已在真硅片验证通过**。
   - 根因已定位：不是工具/SDC/place-route/DSRM 问题，而是**网表级跨实例寄存器合并**（syn_dont_touch 已修复）。200MHz 死循环疑为 138K 布线引擎在超大面积下的收敛极限。
   - 124.3MHz 收敛路径：`board_top_macsplit_reg`（4 引脚 CST + max_fanout=100 + opt_goal timing + route=2/place=3），Fmax=124.311MHz，TNS=-4559。
   - 下一步：若要签核 200MHz，需试官方 demo 工程（led/ddr3_400M）验证是否工具/环境极限；或接受 124MHz 作为当前工作频率继续推进。
   - **向下游（手机端）传递时：先 `git pull`，读 HANDOFF + PNR-EXPERIENCE.md，勿重复跑 4 配置实验。**
3. **三方汇合（13↔14）**：`pcie_dma_engine`（FPGA 权重流）↔ `nvme_bridge`（块请求）↔ `cachectl_pipeline`（wt_lba 落点）语义对上，加回归（仿真桩粒度自己定）。
4. **14 PCIe 硬核真机准备**：EP(T2)/RC(T1) 适配器 = 顶层骨架 + 金手指约束 + 用户照做的 Gowin IDE 清单（`lspci -vv` 目标 Gen3 x4）。Termux 无 Gowin IP，只能到"bitstream 就绪度"。
5. 新代码沿用各支线回归；14 追加 `sim.sh run`；12/13 按各自 tb 单跑。
6. 调试临时文件一律 `/data/data/com.termux/files/usr/tmp/opencode/`。

## 提交规范
- message 风格参考 `git log --oneline -8`；只 stage 本任务文件；`master` 分支不动；push 仅当用户说。

## 终点
~~13 board_top 真机冒烟 PASS（LED 心跳）~~ ✅ 已完成（2026-09-02，124.3MHz，LED 心跳+引擎半亮）。
→ **当前阻塞**：200MHz 签核死循环（Routing Phase 0 卡死），需决定是试官方 demo 工程验证工具极限，还是接受 124MHz 继续推进。
→ 三方对接点清晰 → 14 PCIe 骨架/清单就绪，编译全过、14 回归 22/22 或更多全绿，给出用户 PC/板子上的完整验收步骤与预期数值（含下一次真机步骤）。