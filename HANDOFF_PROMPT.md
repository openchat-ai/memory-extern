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
7. **验证核心假说：专家=公式即库，dense=满秩（桌面已下载完整官方 K3 权重，待跑）**：
   - **核心假说（已从多次验证收敛）**：K3 权重不必全量存 = 专家部分是"公式/查表即数据库本身"（天生紧凑，每权重~5bit，查表+移位GEMV免解压），dense 部分是"满秩量化数据"（省不了低秩那层，只能靠量化打折）。结论必然打折，到不了 0 存储（用户已认同）。
   - **工具已入仓（全验证过）**：
     - `tools/probe_real_weights.py` — 读 safetensors，输出唯一值/二幂/**有效秩占比/低秩b/w**。用法见 `docs/research_weight_probe.md`。
     - `tools/slice_k3_micro.py` — 从完整 K3 切出几百 MB 最小测试包（dense+若干expert+.npy），免反复下载大模型。
   - **桌面动作**：`slice_k3_micro.py` 切真实 K3 文本层 → `probe_real_weights.py` 测，一次定死：
     a. **dense（kda）**：有效秩占比 <~20% → 低秩真可压（创举）；>~50% → 满秩，低秩无效（只余量化）
     b. **routed expert（MXFP4）**：确认唯一值极少 ∧ 强二幂 → 公式/查表假说坐实
   - **已知基线（重要，已修正）**：MXFP4 专家唯一值21/二幂100%；**NVFP4 dense 是满秩**——"前10奇值能量仅1.2%"曾被误读为低秩，累积能量曲线实为 95%能量需55.7%秩=28b/w（几乎不省）。**教训：判低秩必须看累积能量→有效秩，别被前几个奇异值占比误导。**
   - **诚实门槛**：专家=公式真实用，dense 只余量化 → 不是"不须存全权重"，是"专家免解压、dense 压缩"。可发研究、可反哺 memory-extern，但别定位成"划时代 0 存储"。先实测定论再谈价值。结论回传：`git commit`+`git push`（只推<10KB文本），手机端 pull 判读。
8. **（已并入§7）~~划时代门槛/三要素~~** — 待办合并，核心收敛为§7。

9. **MXFP8 无损装 e6m7 验证（关键硬前提，待桌面真实 dense）**：
   - **用户已完成的**：BF16(e8m7,16bit)→e6m7(14bit)量化，实测熵=6.5bit（无损）。**6.5是尺子测得的信息量，不是目标；目标是"用8bit MXFP8 无损装这 6.5bit 信息，且推理无解压动作"。**
   - **已入仓工具（全验证过）**：
     - `tools/quantize_e6m7.py` — BF16→e6m7(14bit)+熵测（用户已手动验证过此步）
     - `tools/mxfp8_pow2.py` — MXFP8 位分配优化：块大小扫描+熵尺子贴近度（e4m3熵6.53≈e6m7的6.5，自洽）
     - `tools/mxfp8_lossless_dist.py` — **精确逐块无损检查**（判据：每块所有e6m7值能否精确落MXFP8格点；高斯下E4M3仅6%，诚实）
     - `tools/mxfp8_lossless_entropy.py` — 熵反推值数（宽松参考，已注明非定论）
   - **硬约束**：无损 + 无解压（MXFP8直接当计算格式，移位GEMV，不还原浮点）。`scale×sign×(1+m/2^M)×2^e`全程移位+加。
   - **桌面动作（一锤定音）**：`python3 tools/mxfp8_lossless_dist.py --raw <真实K3 dense 或 e6m7量化后bin>` → 真实无损率：
     - >99.9% → "MXFP8 无损装 e6m7"成立（创举方向）
     - ~6% → 数学不可行（E4M3尾数3 vs e6m7尾数7），退而二选一：e6m7(14bit)无损 / MXFP8(8bit)有损
   - **信息论锚点**：e6m7 全集16384格点，E4M3全集仅256格点/块；无损只在"分布极偏(高峰)+每块值能精确落格点"时才可能。合成高斯熵10.45≠6.5，不具代表性，**必须真实分布**。
   - **格式死结结论（2026-09-05）**：MXFP8 固定 8bit 格点装不下真实分布——E4M3 覆盖 6.25%，合成高斯逐块无损率仅 6%。**换向：代码本+逃逸（Codebook+Escape），绕开"固定格点"死结，格式适配分布**。原理=专家21值查表的推广：全部唯一值→代码本，每权重存索引(查表=无解压，移位GEMV)，低频尾部值走逃逸通道存原值。
   - **已入仓 `tools/codebook_format.py`**，真实 fixture 验证：唯一值28,722/熵5.49，k=32覆盖88.9%+逃逸11.1%→**平均7.00bit/权重=压缩2x，无损+无解压**。合成高斯唯一值29.9万→代码本无意义，**真实分布唯一值集中才有效**。
   - **存储落地（已拍板的优先级）**：瓶颈是 expert I/O 带宽非容量 → **9bit 对齐存优先（无解压），放弃位打包省2bit（会引回解压）**。fixture 已证 8bit 纯代码本无损不成立（唯一值>256 需15bit索引），**须逃逸**。桌面真实 dense 跑 `codebook_format.py` 拿到唯一值数后，若唯一值集中→7-9bit无损无解压成立；若散→回到二选一。
   - 结论回传：`git commit`+`git push`，手机端 pull 判读。

## 提交规范
- message 风格参考 `git log --oneline -8`；只 stage 本任务文件；`master` 分支不动；push 仅当用户说。

## 终点
~~13 board_top 真机冒烟 PASS（LED 心跳）~~ ✅ 已完成（2026-09-02，124.3MHz，LED 心跳+引擎半亮）。
→ **当前阻塞**：200MHz 签核死循环（Routing Phase 0 卡死），需决定是试官方 demo 工程验证工具极限，还是接受 124MHz 继续推进。
→ 三方对接点清晰 → 14 PCIe 骨架/清单就绪，编译全过、14 回归 22/22 或更多全绿，给出用户 PC/板子上的完整验收步骤与预期数值（含下一次真机步骤）。