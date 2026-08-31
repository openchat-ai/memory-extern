# 通用 SerDes 协议抽象层(SERDES-PROTO)架构设计

> 决策记录(2026-08-30,用户拍板):
> 1. **接口自适应范围**: 写完整抽象层,但第一版只做 **2 个适配器实例**验证架构。
> 2. **验证载体**: 两层都要 —— 先仿真验证协议层,再绑一块板做回环冒烟。
> 3. **性能**: 不锁带宽,参数化/可扩展性做满,带宽由后端接口决定。

## 1. 设计动机 / 为什么是"抽象层"而不是"万能自动识别"

目标: 一套协议层,能贴在任意 SerDes/任意目标硬件上,只要能插上就能用。

**关键认知(避免踩坑)**: 各接口(自定义裸 SerDes / PCIe / 10G 以太网 / DDR)的
PHY 电气、链路训练、编码(8b10b/128b130b)完全不同,不可能用一个"运行时自动探测+切换"
的协议栈全吃——那会吃掉大量 LUT/时序,而且极难验证。

正确做法: **把"与接口无关的流式数据内核"做成固定内核,把"与接口相关的 PHY/适配"做成
可插拔薄适配器**。内核不关心物理是谁,适配器负责把"某接口的电信号"转换成统一的流式接口。
这就是本层架构的核心。

```
   [目标硬件/接口电信号]
          │
   ┌──────▼───────┐
   │ 接口适配器 PHY │  ← 可插拔,一接口一个; 负责电气/训练/编码
   │  (adapter)    │     自定义裸SerDes / PCIePHY / 10GE-MAC / ...
   └──────┬───────┘
          │ 统一流式接口 (AXI-Stream 风格, "背压+tlast+帧头")
   ┌──────▼───────┐
   │ 通用协议内核   │  ← 固定,只认流式接口; 负责帧解析/命令分发/背压
   │  (core)       │     这就是从 pcie_dma_engine.v 抽出来的部分
   └──────┬───────┘
          │ 用户数据通道 (交付给下游 GEMV / 内存 / 应用)
```

## 2. 分层定义

### L0 物理 / PHY(适配器 · 可插拔)
- 贴具体芯片的 SerDes 收发器,负责: 串并转换、CDR、链路训练、PHY 复位/初始化、回环。
- **每个接口一个** `*_phy` 模块。第一版仅实现 2 个(见 §4)。
- 对外统一暴露: 一个"字节/拍流"接口(valid/ready/data/上一次界),不暴露各接口电气差异。

### L1 协议帧(适配器 · 可插拔)
- 把 L0 的原始拍流,按该接口的链路协议组织成**帧**(帧头 + 负载 tlast 界定)。
- 对自定义裸 SerDes: 自己定帧头格式(魔数 + 长度 + CRC)。
- 对 PCIe 风格: 映射到 TLP/流式。
- 统一输出: **标准 AXI-Stream 接口**(tvalid/tready/tdata/tkeep/tlast)。

### L2 通用协议内核(core · 固定,唯一)
- 只认 AXI-Stream,不关心上游是谁。
- 职责: 帧头命令解析、payload 长度计数、tkeep 逐字节选通、背压(ready)、
  多命令分发(推激活 / 跑权重 / 预留验证)。
- **这就是从 `pcie_dma_engine.v` 抽离的接收 FSM**,去掉了 PCIe 特指,改成纯流式。
- 可选内置: 状态计数、错误/丢弃统计(可映射寄存器)。

### L3 应用适配(用户侧)
- 跟具体下游绑定(GEMV-FIFO、DDR 缓冲、结果回传)。
- 在 138K 场景 = `engine_core` / DDR;但本层设计保持中性,不写死。

## 3. 统一接口约定(核心契约)

所有适配器 L1 输出都遵守同一组信号(参数化 DATAW):

```verilog
// 主→从 (下行数据)
output s_axis_tvalid, input s_axis_tready,
output [DATAW-1:0] s_axis_tdata, input tlast/...
// 从→主 (回传,可选)
```

**帧格式**(与 `pcie_dma_engine.v` 同构,促进复用):
- 拍 0 帧头: `[7:0]=cmd`, `[15:8]=seq`, `[23:16]=payload_len(字节)`
- 拍 1..N 负载: 每拍 `DATAW/8` 字节,`tkeep` 逐字节选通,`tlast` 标末拍

背压契约: 内核在"装帧 + settle"期间拉低 `tready`,适配器/上游暂停——**保证
'清→装→累加'顺序,绝不丢结果**。

## 4. 第一版两个适配器实例(验证架构)

### 实例 A: 自定义裸 SerDes 点对点(custom_serdes)
- **L0**: 一个参数化的 8b/10b(或透传)串行 PHY 模型,仿真里用回环(loopback)验证。
- **L1**: 自定帧头(魔数 `0x5A5A` + 长度 + CRC8),把拍流组织成帧。
- **价值**: 证明"抽象层对 PHY 无依赖",自定义接口能通。

### 实例 B: AXI-Stream / PCIe 风格(axis_pcie)
- **L0/L1**: 直接把适配器做成"透传 AXI-Stream"(模拟 PCIe IP 的 AXI-Stream 出口)。
  即: PCIe 的 gowin_pcie_ip 出 `s_axis` 就直接喂进内核——适配器只是"胶水 + 复位/握手"。
- **价值**: 证明"已有 PCIe IP 能无缝接到本内核"(这正是 138K 的主流用法)。

两个实例共用同一个 L2 内核 → 证明"内核通用、适配器可换"。

## 5. 参数化 / 可扩展机制

- `DATAW`(流宽,128/256/512): 一拍字节数。
- `CMD_*`: 命令表参数化,新增命令不需改内核。
- 适配器注册表(文档/注释): 每加一个接口,只需新增一个 `*_phy` + `*_framer` 薄层,
  内核零改动。
- 带宽不由内核决定,由后端接口/适配器决定 → 可扩展性做满。

## 6. 验证策略(两层)

### 第一层: 纯仿真(先行,不依赖硬件)
- iverilog 12.0,需 `-g2012`;输出只能放 `/data/data/com.termux/files/usr/tmp`。
- 通用 testbench: 直接驱动 AXI-Stream,喂"帧头+负载",断言内核正确解析/分发/背压。
- 实例 A 用回环: 发送端→适配器→回环→接收端,走通自定义协议。
- 实例 B: 模拟 PCIe 上游 burst,验证帧拆分/背压/结果不丢。

### 第二层: 板级回环冒烟(后续,需载体确认)
- 绑具体板位(138K 或用户确认的其它板),生成 bitstream,SerDes 回环自测。
- 验证跑到真实电接口,不只在仿真里。

## 7. 高速路径与速度档位(物理能力映射)

138K 目标板 = **GW5AST-138**,拥有 8×12.5Gbps 独立 SerDes 收发器 + 硬核 PCIe 3.0
(板上 4 lane ×5G = 20Gbps) + 2× SFP+ 光口 + MIPI D-PHY + LVDS GPIO。
两条高速路径均已完成仿真验证(见 §9)。

### 两层速率语义(务必分清)
- **电气层 Gbps** = 每 lane 每 clk 传 1 bit,`N_LANE × clk`。
- **逻辑层有效吞吐**受上层 AXI/内核"每拍 1 字节"上限约束,实测稳定字节率 =
  `min(N_LANE/8, 1)` 字节/拍(N=1→0.125, N=4→0.5, N=8→1.0 饱和)。

### 路径 1: SFP+ / SerDes 10G(adapter/sfp_serdes)
- L0 换成 `serdes_phy_sfp.v`(词级延迟管线 + RX 弹性 FIFO,`DATAW/LINE_RATE/
  RX_DEPTH/LINK_LAT` 参数),通过 `serdes_link` 的 `PHY_TYPE` 参数切换实例化——
  **协议层零改动**,证明"可插拔接口适配器"成立。
- 实测: N=8 lane 聚合 1.000 字节/拍(理论 min=1.0,饱和)。

### 路径 2: PCIe 20G(adapter/axis_pcie/gw_pcie_bridge.v)
- 桥内嵌 `proto_core`,RX: gowin_pcie_ip 的 M_AXIS → 内核解码;
  TX: 载荷 echo 回 S_AXIS。`o_payload_*` 直连 `pcie_tx_*`,`o_payload_tready =
  pcie_tx_tready`,以内核背压保证不丢字。
- 实测: 3 帧 PCIe 流 → 内核 → 载荷回程,随机 25% 背压下零错·保序·完整。

### 吞吐档位实测表(满载荷边界)
| N_LANE | 电气 | 逻辑吞吐(字节/拍) | 实测 | 说明 |
|--------|------|-------------------|------|------|
| 1      | 1×clk | 0.125            | 0.125 | 单 lane 槽位固有 2 拍气泡 |
| 4      | 4×clk | 0.5              | 0.5   | 部分 lane 槽位气泡 |
| 8      | 8×clk | 1.0              | 1.000 | 聚合饱和,受上层 AXI 每拍 1B 限制 |

> N=1 的 `0.125` 是 `serdes_link` round-robin 槽位语义的固有气泡
> (`lane_tx_valid` level 保持 + `tx_ready` 恒 1 时 `fire_take` 节拍),**不是错误**。

## 8. 目录规划

```
rtl/14_serdes_proto/
  doc/ARCHITECTURE.md        ← 本文档
  core/                       ← L2 通用协议内核(唯一)
    proto_core.v              (从 pcie_dma_engine.v 抽离的纯流式内核)
  adapter/
    custom_serdes/            ← 实例 A(逐位 PHY)
      serdes_link.v           (可插拔聚合层,PHY_TYPE 参数选 PHY)
      serdes_phy.v            (PHY_TYPE=0 逐位 L0 模型)
      serdes_phy_sfp.v        (PHY_TYPE=1 词级 SFP+ 适配器)
      serdes_framer_tx/rx.v, crc16.v
      tb_load.v / tb_link.v / tb_edge.v ...
    sfp_serdes/               ← 路径1: SFP+/SerDes 10G
      serdes_phy_sfp.v, tb_sfp_load.v
    axis_pcie/                ← 路径2(实例 B): PCIe 风格
      axis_pcie_adapter.v, tb_axis_pcie.v
      gw_pcie_bridge.v, tb_gw_pcie_bridge.v   (Gowin PCIe IP ↔ proto_core 桥)
    path_cache/               ← SSD 双路径自动识别 + 统一权重流(缓存控制器做实)
      links_detect.v          (复位探测 SerDes对齐 vs PCIe link-up, 先到先得锁定)
      path_mux.v              (按锁定路径选通统一权重流 -> GEMV)
      expert_dir.v            (专家 LRU 缓存目录: trunk 恒驻留 + LRU 替换 + 动态更新)
      cachectl_pipeline.v     (端到端: 探测+选通+LRU目录+GEMV+文件→LBA, 冷首访单拍装入)
      file2lba.v              (文件→LBA 映射: 分区起始+extent表, 真机按地址读盘接口)
      ext4_scan_core.v        (RTL ext4 扫描: 块流→superblock/组描述符/→inode/目录树)
      cachectl_top.v          (骨架版: 权重通路 + 命令来源可切)
      tb_path_cache.v, tb_expert_dir.v, tb_cachectl_pipeline.v, tb_file2lba.v
      tb_ext4_scan.v          (ext4 扫描 RTL 验证: 合成镜像喂块)
  tb/ proto_core_tb.v
  sim.sh                      ← 一键回归(现 18 测试全绿,见 §9)
```

## 8a. SSD 双路径自动识别(L2缓存场景, path_cache)

场景: 冷存储(HDD, 全量权重) + L2缓存(SSD, trunk+每层激活专家,**专家动态更新**)。
同一块 SSD 可物理插在 **FPGA 板上 M.2**(路径1/SerDes) 或 **PC 主板 M.2**(路径2/PCIe)。

关键结论(与用户对齐): 不做"运行时不停重切",而是**复位后一次性探测 + 先到先得锁定,
不复切**。理由: 一块盘只能在一个 M.2 槽(两路物理互斥),无需仲裁歧义。

### 自动识别机制
- 就绪信号(被动采样,不驱动链路):
  - 路径1 = `serdes_phy_sfp` 的 `rx_ip_aligned`(本地盘在 → SFP 对齐)
  - 路径2 = PCIe 硬核 link status(主机盘在 → PCIe link-up)
- `links_detect`: 复位后第一个就绪边沿锁定 `sel`,之后不再变(两路都就绪时默认本地)。

### 统一出口(核心契约)
- `path_mux`: 按 `sel` 选通一路作为**唯一权重流** `wt_valid/wt_data/wt_ready`。
  GEMV(`engine_core`)只认这一对握手 → **无论 SSD 在哪条路径,GEMV 全程无感知**。
- 未锁定(`locked=0`)时强制不输出,防止识别期权重混入。

### 命令来源可切
- `CMD_UPDATE_EXPERT`(0x40)帧: 帧头 `[7:0]=cmd [15:8]=seq [23:16]=len`,
  载荷 `[7:0]=expert_id`。命令流独立窄通道(避免与权重块混帧)。
- 本地(A) / 主机(B) 任一来源进入,均收敛到同一命令处理点,`last_src` 记录真实来源
  → 证明"专家动态更新"动作出处可切。

### 缓存目录做实(expert_dir + cachectl_pipeline)
- `expert_dir`: 槽0=trunk(永久驻留,恒命中), 槽1..S-1=专家 LRU 槽。
  - 每槽 rcnt 相对旧度计数(命中/装入/更新即置 0=MRU, 其余 +1); rcnt 最大者=LRU。
  - 未命中 → `req_way` 给出待替换 LRU 槽; `load` 装入后该专家命中。
  - `req_*` 为**组合输出**(读稳定目录快照), 与源桩同拍对齐 → 无寄存器滞后错位。
  - 存储(槽数组)时序非阻塞更新, 无 delta 竞态。
- `cachectl_pipeline`: 端到端链路 `links_detect → path_mux → expert_dir → GEMV`。
  - **每字单拍完成**: trunk→出 trunk 权重; 命中→出目录权重; 冷首访→出源桩原字并
    **同拍自动装入目录**(miss 即 load, 无恢复拍、无 valid 多拍重复问题)。
  - 统计: 每拍 `src_valid` 按 trunk/hit/miss 计数; miss 同拍 `misses++`+`loads++`。

### 文件→LBA 接口(file2lba, 真机按地址读盘)
- 背景: 缓存磁盘多为分区, 缓存文件落在**最大的 ext4 分区**的多个目录下。RTL 只能
  按磁盘 LBA 读块, 需把"(文件句柄, 文件内块号)"翻译成物理 LBA。`pipeline` 每字
  tag 作文件内块号, 组合直出伴随 `wt_lba`(与权重同拍), `lba_fault` 标越界。
- `file2lba` 表(宿主工具解析分区/ext4 后经命令帧写入):
  - `part_lba`: 缓存分区起始物理 LBA(高16+低32 两次配)。
  - **extent 段表(全局拼接)**: 每段 = 分区内相对 `base_lba`+`cnt`; 逻辑起点依次
    累加, 覆盖所有文件的全部 extent。
  - **文件目录(多文件句柄)**: `F[f].base`(该文件在全局逻辑块空间中起点)+`size`
    (文件块数判界)。
  - 查询: `gblk = F[f].base + 文件内块号`; 物理 LBA = `part_lba + 段base +
    (gblk - 段起点)`; 越界 fault=1(句柄越界/文件内块号超 size/未落入任何段)。
- 命令帧: `CMD_CFG_LBA(0x50)` 共用命令流(帧头 `[15:8]=reg_addr` + 载荷 data),
  与 `CMD_UPDATE_EXPERT(0x40)` 互不干扰(各解码器自挑帧)。寄存器追加
  `0x30+2f` base / `0x31+2f` base_hi / `0x40+f` size。
- **宿主侧 `tools/locate_cache_lbas.py`**: 自动找最大 ext4 分区, **递归遍历分区下
  所有目录**, 收集每个文件的 extent, 汇总成文件→LBA 映射(不筛选文件)。

### RTL ext4 扫描器(ext4_scan_core, 逐级扩展中)
- 目标: 把"扫描目录/找文件→LBA"也搬进 RTL(宿主工具定位结果作参照)。**已完成阶段1-7**:
  窄总线(32bit×NBEAT=1024 拍=4096B/块)从块流灌入——阶段1 解析 superblock
  (`blocks_per_grp`/`inodes_per_grp`/`inode_size`, 块0 偏移1024=字256) 与组0 描述符
  (`inode_table_blk`, 块1); **阶段2** 循 inode 表块读根 inode(2), 采出 `i_mode`/
  `i_size`/extent 头(magic+F30A/entries)/首 extent(`ee_block/ee_len/ee_start`);
  **阶段3/4** 循根目录首 extent 指向的数据块, 用**字节游标(dpos)按 rec_len 逐条遍历**
  `dir_entry2`, 枚举全部有效条目(遇 `ino==0`/越界/满 MAXENT 停)写进**结果表
  (out_ino/out_ftype/out_name/out_count, MAXENT 可配)**; **阶段5/6** 演示单文件 inode
  extent 解析(depth0 内联叶 `f_*` / depth>0 索引递归 `s_*`, 见历史提交); **阶段7** 读
  inode 表块**一次**, 以 `(ino-1)%16*64` 动态定位每个文件 inode 的块内 word, 遍历结果表
  全部文件、**depth=0 内联叶逐个收集**成"文件→物理块"映射表 `ext_ino/ext_ebe/ext_elen/
  ext_estart + ext_count`(depth>0 索引文件跳过)——这是最终通用路径, 取代阶段5/6 的单文件
  演示(其端口/状态保留在 core 但不再被主流程触发)。→"文件名→inode→extent→物理块"
  的 RTL 落点与 `file2lba`/`ext4_lba.py` 对齐。
  后续按序扩展: 全文件 **extent 深度递归**(>0 也收集, 而非跳过)→多目录递归→写外置表 RAM 供
  cache 管线查询。
- 字段抽取用**32 位字数组 wbuf** + 顶取字组合读(规避这版 iverilog 对 `always@(*)` 内数组读的
  组合环 bug; 字节数组+拼接在时序块内同样受限, 故统一用字数组); 遍历用 `wbuf[dpos>>2]`
  位移索引(iverilog 验证可行); 阶段7 动态 inode word 用 `((ino-1)&15)*64` 求模定位(迭代读
  `out_ino[fidx]` reg 数组时 `for`/时序动态索引可行)。**unpacked 数组端口需要 `-g2012`**(sim.sh 已用)。
- **仿真范围(坦诚说明)**: 真机磁盘块读(NVMe 读引擎/138K 板)是硬前置且未到手, 当前
  只对合成镜像块流仿真验证; 完整 ext4 边角(内联数据/深层索引递归/跨块目录)工作量大、
  可验证性有限, 按"每阶段先编译+仿真通过再扩展"推进。

> 简化(仿真范围): 真实 NVMe/M.2 读盘需 NVMe 协议栈,本实现用"外部字流桩"模拟磁盘块;
> trunk 视为永久驻留(冷数据由 HDD 提供),专家 LRU 部门已做实(命中/替换/动态更新/统计)。

## 9. 验证现状(sim.sh 一键回归 18/18 ALL GREEN)

| # | 测试 | 覆盖 |
|---|------|------|
| 1  | proto_core | 内核帧解码+载荷交付 |
| 2  | axis_pcie | 适配器 B + 内核端到端 |
| 3  | custom_serdes | 实例 A 回环 3 包 |
| 4  | crc_check | CRC-16 篡改检测 |
| 5  | varlen | 可变帧长 4/16/64 + CRC |
| 6  | phy_rx_backpressure | PHY RX FIFO 背压无丢 |
| 7  | crc16 | CRC-16-CCITT 标准向量 |
| 8  | multilane | 多 lane 聚合保序 |
| 9  | multilane_e2e | 多 lane 端到端 3 帧 |
| 10 | edge | 边界扫描 8 组 |
| 11 | load | 满载边界 N=1/4/8/16 |
| 12 | sfp_load | 路径1 SFP+/SerDes 满载 N=1/4/8 |
| 13 | gw_pcie_bridge | 路径2 PCIe 桥 3 帧背压回程 |
| 14 | path_cache | SSD 双路径自动识别+统一权重流+命令来源可切 |
| 15 | expert_dir | 专家 LRU 缓存目录: trunk 恒命中+LRU替换+动态更新 |
| 16 | cachectl_pipe | 端到端: 探测+选通+LRU目录+GEMV+文件→LBA(冷首访/重访/trunk/更新/主机路径) |
| 17 | file2lba | 多文件句柄→LBA: 分区起始+全局extent表+文件目录+跨段+越界+动态重配 |
| 18 | ext4_scan | RTL ext4 扫描: 阶段1 superblock+组0desc → 阶段2 根inode(2) → 阶段3/4 目录块rec_len逐条枚举→结果表 → 阶段7 全文件遍历(动态 inode word 定位)→"文件→物理块"映射表(索引文件跳过) 合成镜像闭环 |

> **proto_core 背压修复(本版本)**: `o_payload_*` 改为组合直通 + `s_axis_tready`
> (PAYLOAD)=`o_payload_tready` 同拍握手;背压时 `s_axis_tready=0` 刹停上游、数据
> 保持 → 随机背压下**零丢字节**且不降吞吐(此前滞后一拍寄存器在随机背压下丢末帧)。

## 10. 与既有代码的关系

- **复用**: `pcie_dma_engine.v` 的接收 FSM(帧头+负载+tkeep+tlast+SETTLE 背压)
  抽成 `proto_core.v` 内核。其结果回传部分保持 AXI-Stream。
- **不改**: 既有 `engine_core` / GEMV / DDR RTL 不动。
- **138K 落地**: 实例 B 的 `axis_pcie_adapter` 直接对接 gowin_pcie_ip 的 AXI-Stream,
  即为 138K 主用路径;实例 A 展示"任意 SerDes 也能贴"。
