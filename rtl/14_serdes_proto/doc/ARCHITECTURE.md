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
- 目标: 把"扫描目录/找文件→LBA"也搬进 RTL(宿主工具定位结果作参照)。**已完成阶段1-17**:
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
  演示(其端口/状态保留在 core 但不再被主流程触发); **阶段8** 把映射表**同步落进外置表
  RAM**(`ram_ino/ram_ebe/ram_elen/ram_estart`, 扫描写入), 并提供**独立查询 FSM**(按
  `qino` 线性遍历 RAM, 返回该文件的物理块段 `qebe/qelen/qestart + qvalid/qdone`,
  未命中则 qvalid=0); **阶段9** 对 **depth>0 索引文件**不再跳过, 而是**递归下钻**(暂存
  `cur_ino_r`, 循 `ei_leaf` 读子 extent 块, 遍历其全部叶 `wbuf[3+i*3]` 收集进表/RAM,
  S_SUBLF 循环至子块 `sentries`, 再回主循环) — 支持索引文件多叶, 覆盖真实大文件 ——
  **阶段10** 泛化为**多层深度递归**: S_SUBP 先查该子块 depth, 若子块仍是**索引块**(depth>0)
  则对第一索引项 `ei_leaf=wbuf[4]` **继续下钻**(cdepth 计数, 超 MAXDEPTH 报 err), 直到
  叶块再遍历收集 — 支持嵌套 2+ 层索引块 ——
  **阶段11** 增加**一级子目录递归**: 收集根目录文件时**跳过 type=2 目录条目**, 完成后在
  out_ftype 里定位子目录(S_DMSCAN), 读其 inode(w=((ino-1)&15)*64)取数据块, 枚举子目录
  **内联叶/块内文件** S_DBLOOP 收集 subd_ino[], 重读 inode 表块逐个解析子文件 extent 续写
  进 ext/RAM 表(S_DMEXT) — 支持"根目录 + 一级子目录"两层的全文件系统收集 ——
  **阶段12** 把索引下钻从"只跟第一索引项"泛化为**索引块多路遍历**: 首次进入索引块时存其块号
  (sidx_blk_r)并初始化索引项游标 si(0..sientries-1), 逐项下钻 `ei_leaf`(wi+1 项 =
  wbuf[3+(si+1)*3+1]), 每读完一个叶块收集其叶后**重读索引块取下一项**(sinidx 标志区分
  首进/遍历中; S_SIREQ/WAIT/FILL/SIP), 直到全部索引项处理完回主循环 — 支持真实大文件
  (一个索引块多个 ei_leaf 指向多个叶块) ——
  **阶段13** 把 inode 定位从"固定 inode 表单块(块4, per_block=16)"放宽为**跨多块 inode 表**:
  子文件收集(S_DMREQ2)改读 `itbl_r + ((first_subd_ino-1)>>4)` 物理块(per_block=16), 块内
  word 仍用 `((ino-1)&15)*64` — 支持真实 ext4 一组 inode 表跨多块、inode 号跨块分布;
  (镜像: 子文件 ino17/18 → inode 落在 itbl+1=块5, 块内 word0/64) ——
  **阶段14** 把定位从"只组0 一块 inode 表"推广为**多 blk_groups**: 收集开始(S_GDT_P)读
  GDT(块1) 存各组 `bg_inode_table_lo` 到 gdt_itbl[0..3](组域 word 组号*16+2), superblock
  存 inodes_per_grp(ipg_r); inode 定位统一为 `grp=(ino-1)/ipg_r`,
  `物理块 = gdt_itbl[grp] + (((ino-1)%ipg_r)>>4)`, `块内 word = (((ino-1)%ipg_r)&15)*64`;
  S_EXT_LOOP/S_DMREQ/S_DMREQ2 均按此, 并用 curi_blk_r 跟踪当前 wbuf 的 inode 表块,
  字段所需的 inode 表块不同则重读 — 支持真实分区 (inode 号动辄上万必然跨组) ——
  **阶段15** 把"根+一级子目录"推广为 **任意层级目录递归(目录栈)**: 加入目录栈 dir_stk[]/stkp,
  S_DMSCAN 一次把根目录所有 type2 条目**压栈**, 枚举任意目录块(S_DBLOOP)时遇 type2 内层子目录
  也**压栈**(type1 记录待收 extent); S_DMPOP 弹栈取栈顶目录(跨组定位其数据块+枚举+收文件 extent),
  S_DMEXT 收完一层文件后回 S_DMPOP 处理下一层, 栈空结束 — DFS 深度优先遍历任意深度目录树 ——
  **阶段16** 把查询面从"只找 ino 返回首 extent"扩展为 **cache 查询闭环**: 查询入参加
  `qblk`(文件内逻辑块号)+`part_base`(分区起始物理 LBA), 查询 FSM 按 (qino,qblk) **跨 extent
  累积**(q_off 累加每段 elen), 命中所在段输出 **绝对物理 LBA** `q_lba=part_base+estart+
  (qblk-q_off)`, 未找到 ino / qblk 超文件总长 → `q_fault=1` — 使扫描生成的 RAM 表直接成为
  查询源, "扫描→索引→(ino+块号)→绝对LBA"闭环, 与 file2lba 语义一致(该模块按文件句柄,
  此处按 inode) ——
  即"文件 inode→物理块段"的可查询映射, 正是 `file2lba` 的"文件→LBA"查询在 RTL 的落点。
  →"文件名→inode→extent→物理块→绝对LBA"闭合链完整, 与 `file2lba`/`ext4_lba.py` 对齐。
  说明: 收集表容量用独立参数 TABN(默认8, 须 >MAXENT 以容纳递归展开), 目录枚举容量仍 MAXENT
(每层各自), 目录栈深度参数 NDEP; per_block 仍硬编码=16(isz=256), ipg 由 superblock 运行时读入;
   阶段17c(件3) 起同一目录的多个文件 inode **不再假设同表块**: 每文件按 `gdt_itbl[grp]+((ino-1)%ipg_r)>>4`
   独立定位, 跨块自动重读。
  **阶段17** 把 `ext4_scan` **实际例化接线进缓存管线** — 新建 `cache_lba_top.v` 同时例化
  `ext4_scan_core U_scan` 与 `cachectl_pipeline U_pipe`: reset 后 T_FSM 自动拉 scan_go 扫描块源,
  done 后 TSP 遍历 ext4_scan 的 RAM 表挑出 FILE_INO 目标文件的 extent 段, 转录 FSM(TF0/TF1 逐帧)
  把 `{part_lba, EXT[k] base/cnt, F[0] base/size}` 写成 CMD_CFG_LBA(0x50) 双击帧打进
  `U_pipe.cmd_b`(独占 cmd_b, 外部命令走 cmd_a 互斥) — 即把"宿主工具手动预配 file2lba"换成
  **ext4_scan 扫描结果自动转录**, 转录完 lba_ready=1; 之后管线权重字流每字 tag=文件内块号,
  `U_pipe` 的 file2lba 组合直出绝对物理 LBA(wt_lba) 供真机按地址读盘。仿真实例天然覆盖 ino14
  (多索引叶): 叶0(逻辑0,estart300,len1)+叶1(逻辑1-2,estart310,len2), tag=0→part+300、
  tag=1→part+310、tag=2→part+311 — **"扫描→索引→转录→查询→读地址"完整模块层级链路闭合**。
后续按序扩展: 多层索引**嵌套+多路**→大文件 i_extra/indirect+extent混合→同一目录多文件跨 inode 块收集→
   多文件目录转录(当前转录固定 FILE_INO 单文件, 递推全文件目录需扩展 TSP 遍历 RAM 表所有 inode)→真机绑板接线。
   **阶段17b(件2)** 把索引递归升级为 **DFS 节点栈**: 新增 `node_blk/node_cnt/node_ent` 当前节点游标
   + 祖先节点栈 `estk_blk/estk_cnt/estk_ent` + `estkp` 栈指针, 取代原单索引块 `sinidx/si/sientries`
   单层多路逻辑。`S_IDXENT` 每次下钻索引项前压栈当前节点, 叶收集完(S_SUBLF)或节点耗尽(S_IDXENT
   弹栈)统一回溯重读父节点块; 支持任意深度嵌套索引(MAXDEPTH=4 防护)+每层多路。仿真实例新增 ino22
   深度3 嵌套大文件: 根(索引,depth3) → 块60(depth2) → 块61(depth1,2索引项) → 叶块62(estart900)/63
   (estart910), 2 叶全部收集; TABN 默认 8→16 容纳递归展开。
   **阶段17c(件3)** 把根/子目录文件收集统一进 S_EXT_LOOP 两分支, 新增 `sel_dm`(0=根 out_ino,
   1=子目录 subd_ino)与统一游标 `fidx`; 取消"同目录文件须同 inode 表块"假设 — 每个文件按
   `gdt_itbl[grp]+((ino-1)%ipg_r)>>4` 独立重定位, 跨块自动重读(S_EXT_REQ)。仿真实例子目录 sub1
   同时含组1 文件 ino17/18(表块6)与组0 文件 ino12(表块4), 跨 inode 表块收集验证。
   **件1** cache_lba_top 转录升级为**多文件全目录**: TSP 遍历 RAM 表全部 extent, 按 ino 分组
   (每组=一个文件句柄 F[f]), 全局逻辑块号拼接: 同 ino 多段连续写全局 EXT[k], 每组边界封
   F[f].base(累计 base)/size(本组块数)。仿真实例 RAM 共 6 文件(ino12/13/14×2/17/18/19)
   → file2lba 目录 F[0..5] base/size 全部正确, extent 段(estart32/48/300/310/400)拼接正确;
   管线按 file0=ino12 查询: tag0→part+32、tag1→part+33、tag2(越界)→fault。
   **件4** cache_lba_top 从"TD 自动回 TI 无限重扫"改为 **TIDLE 保持态**: 转录完成后 lba_ready=1
   恒置、tst 停在 TIDLE 不再自动循环; 新增 `rescan` 输入, 拉高才回 TI 触发重扫, 重扫后目录
   与查询结果保持正确(可重复)。
   后续待办: 大文件 i_extra/indirect+extent 混合、真机绑板接线(NVMe 读引擎)。
- 字段抽取用**32 位字数组 wbuf** + 顶取字组合读(规避这版 iverilog 对 `always@(*)` 内数组读的
  组合环 bug; 字节数组+拼接在时序块内同样受限, 故统一用字数组); 遍历用 `wbuf[dpos>>2]`
  位移索引(iverilog 验证可行); 阶段7 动态 inode word 用 `((ino-1)&15)*64` 求模定位(迭代读
  `out_ino[fidx]` reg 数组时 `for`/时序动态索引可行); 阶段8 查询用**独立时序 FSM**线性遍历
  RAM(组合 for 遍历在 `always@(*)` 会组合环, 故按拍比较)。**unpacked 数组端口需要 `-g2012`**(sim.sh 已用)。
- **仿真范围(坦诚说明)**: 真机磁盘块读(NVMe 读引擎/138K 板)是硬前置且未到手, 当前
  只对合成镜像块流仿真验证; 完整 ext4 边角(内联数据/深层索引递归/跨块目录)工作量大、
  可验证性有限, 按"每阶段先编译+仿真通过再扩展"推进。

> 简化(仿真范围): 真实 NVMe/M.2 读盘需 NVMe 协议栈,本实现用"外部字流桩"模拟磁盘块;
> trunk 视为永久驻留(冷数据由 HDD 提供),专家 LRU 部门已做实(命中/替换/动态更新/统计)。

## 9. 验证现状(sim.sh 一键回归 19/19 ALL GREEN)

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
| 18 | ext4_scan | RTL ext4 扫描: 阶段1 superblock+组0desc → 阶段2 根inode → 阶段3/4 目录rec_len枚举→结果表 → 阶段7 全文件收集 → 阶段9/10 索引多层递归下钻多叶(MAXDEPTH) → 阶段12 索引块多路遍历(全部 ei_leaf) → 阶段11 一级子目录递归 → 阶段13 跨多块 inode 表 → 阶段14 多 blk_groups 定位(GDT多组域+ipg) → 阶段15 任意层级目录递归(目录栈) → 阶段16 查询闭环(qblk跨extent累积→绝对LBA+越界fault) → 阶段8 落外置表RAM+查询FSM |
| 19 | cache_lba_top | 阶段17 例化接线: ext4_scan_core+cachectl_pipeline 同层, reset 自动扫描→读 RAM 表→转录 FSM 把 FILE_INO 目标文件 extent 写成 file2lba 配置帧(打 cmd_b)→lba_ready 后管线 tag=文件块号直出绝对 LBA(ino14 多叶 0→+300/1→+310/2→+311) — 扫描→索引→转录→查询→读地址 全链路闭合 |

> **proto_core 背压修复(本版本)**: `o_payload_*` 改为组合直通 + `s_axis_tready`
> (PAYLOAD)=`o_payload_tready` 同拍握手;背压时 `s_axis_tready=0` 刹停上游、数据
> 保持 → 随机背压下**零丢字节**且不降吞吐(此前滞后一拍寄存器在随机背压下丢末帧)。

## 10. 与既有代码的关系

- **复用**: `pcie_dma_engine.v` 的接收 FSM(帧头+负载+tkeep+tlast+SETTLE 背压)
  抽成 `proto_core.v` 内核。其结果回传部分保持 AXI-Stream。
- **不改**: 既有 `engine_core` / GEMV / DDR RTL 不动。
- **138K 落地**: 实例 B 的 `axis_pcie_adapter` 直接对接 gowin_pcie_ip 的 AXI-Stream,
   即为 138K 主用路径;实例 A 展示"任意 SerDes 也能贴"。

## 11. NVMe Host 架构设计(真机磁盘块读写的地基, 待实现)

> 现状: 真机磁盘块读(NVMe 读引擎/138K 板)一直用"外部字流桩"模拟磁盘块,
> 尚未实现真正 NVMe 主机控制器。本节定架构与工作量, 作为下一阶段实现蓝图。

### 11.1 为什么需要它(需求闭环)

SSD 缓存两端数据流最终要落地:
- **读**: GEMV 顺序读权重 → 按 ext4 索引得到 LBA → 从 M.2 SSD 读对应块 → 进 GEMV。
- **写**: WSL/主机低频更新缓存 → 经外部通道 → 把数据写回 SSD 对应 LBA。
- 两路都要求 FPGA **真正通过 SerDes→M.2 对 SSD 发 NVMe 命令**。
  "总线字流桩"换成真 NVMe host 是唯一物理前提。

### 11.2 分层(沿用本项目"物理无关 + 可插拔适配器"哲学)

```
  应用层(已有, 不再动)
    ext4_scan_core  文件→(ino,LBA)       [已实现, RTL自解析]
    file2lba        文件块号→绝对LBA      [已实现]
    cachectl_pipeline 缓存目录+路径选择   [已实现]
            │  读: LBA 序列 / 写: (LBA, 数据块)
            ▼
  ┌─ NVMe 协议层(nvme_host)  ◄── 物理无关, 本层要新实现 ──┐
  │   · Admin Queue: Identify / Set Features / Get Features│
  │   · I/O SQ/CQ: Read/Write 命令                        │
  │   · Doorbell 通知 + 完成队列处理                       │
  │   · PRP/DMA: 数据搬运(读入权重组 / 写回缓存块)        │
  └───────────────┬─────────────────────────────────────-┘
                  │  "标准命令接口"(TLP 风格或自定义流)
                  ▼
  ┌─ 可插拔物理适配器(仿照 proto_core / serdes_link) ────┐
  │   A) Gowin PCIe 硬核(AXI-Stream)  → 接主机金手指      │
  │   B) 自定义 SerDes 桥(serdes_link) → 接 M.2 转接      │
  └───────────────────────────────────────────────────-┘
```

要点: **NVMe 命令层与"跑在 PCIe 硬核上还是自定义 SerDes 桥上"解耦**。
只要上层(ext4/file2lba)给出"读 LBA X / 写 LBA X + 数据", NVMe 层就把它们
翻译成本机的 Admin/I/O 命令;物理适配器只负责把命令/数据搬到对应 SerDes。
这复用了本项目一贯的抽象层方法论, 也保证**物理接法确认前不白做 RTL**。

### 11.3 模块划分(建议新增目录 adapter/nvme/)

| 模块 | 职责 | 依赖 | 是否复用既有 |
|------|------|------|--------------|
| `nvme_admin.v` | Admin 队列: Identify(控制器/命名空间)、Set/Get Features、初始化握手 | 自实现 | 新 |
| `nvme_io.v` | I/O SQ/CQ: Read/Write 命令、命令/完成条目组帧、doorbell 推进 | 自实现 | 新 |
| `nvme_prp.v` | PRP 列表展开 + DMA 搬运(读数据回权重组 / 写数据出缓存块) | 自实现 | 新 |
| `nvme_dma.v` | 数据搬运用 AXI-/串行供料接口, 对接 GEMV 权重组与外写数据 FIFO | 自实现 | 新 |
| `nvme_top.v` | 顶层: 组装各子块 + 暴露"读/写命令接口"给 ext4/file2lba | 新 | 部分复用握手惯例 |
| `phys` 适配器 | PCIe 硬核 axis / 自定义 SerDes 桥, 二选一插拔 | 参考 `gw_pcie_bridge.v` | 复用模式 |

### 11.4 关键接口契约(草案)

- **命令接口(上层→NVMe)**: `(req, is_read, lba[47:0], blk_len, data_fifo_*)`
  - 读: FIFO 输出权重组字节流(喂 GEMV);  写: FIFO 输入待写缓存块。
- **NVMe 层→物理**: 标准化命令/数据搬运接口, 由 phys 适配器映射为
  PCIe TLP(硬核 axis)或自定义 SerDes 帧(自定义桥)。
- 队列状态: admin_q 就绪位 / io_q 深度、doorbell 地址, 均做成参数+可综合 reg。

### 11.5 工作量/风险分解(诚实评估)

> **拓扑决策(2026-09, 实板运输前, v2 已按原理图更正)**: 目标形态 **T1 = FPGA 直挂
> NVMe 盘**(FPGA 当 NVMe 主机)为主, 但先把 **T2 = PC 居中**当过渡验证路径。
> **原理图已确认(2026-09, 来自 Sipeed Pro Dock schematic `SDIO&M.2.kicad_sch`, 非猜测)**:
> - 板载 **M.2 座(B-key)只接了 Q1 通用 SerDes 的 2 路 lane**(`Q1_DAT2/Q1_DAT3`)
>   + `Q1_REFCLK0`**参考时钟, 不在 PCIe 硬核上**。
> - **PCIe 硬核(GW5AST-138, 支持 RC+EP 双模式, 见 DS981/DS1104E)** 只接到 **Q0**,
>   物理上只到板子自身 **PCIe 金手指边缘接口**(x1/x2/x4, Dock 标称 4 lane)。
> - 推论: 想在**板载 M.2 座**上驱动 NVMe 只能走 N5(fabric 用 Q1 SerDes 重写
>   PCIe 栈); 想用**硬核 N4** 则 SSD 必须插在**金手指**那一路。
> - **T1 落地首选(已定)**: NVMe 盘经 **M.2→PCIe x4 被动转接卡**(纯布线无芯片)
>   插到板子自己的 PCIe 金手指, FPGA 当 RC、盘当 EP → 硬核 N4 直连, 避开 N5。
> - T2 接线: SSD 挂 PC 主板 M.2(芯片组当 NVMe 主机) → 数据经 PCIe 总线 →
>   FPGA 插 PC PCIe 槽当**端点加速卡**。先真机冒烟 **N4 物理适配器(硬核 axis)**——
>   `lspci -vv` 能枚举出 Vendor/Device ID + link training 上 Gen3 x4, 就是
>   硬核路径的真机 PASS。随后 T1 只需角色对调(FPGA=RC), 适配器逻辑复用。
> - T2 数据路径: SSD → PC 主机内存 → PCIe(H2C/C2H DMA) → FPGA; 等价于把
>   "板载 NVMe 主机层"暂时后移到 PC, 由 PC 承担盘管理与驱动。

| 阶段 | 内容 | 工作量 | 关键风险 / 前置 |
|------|------|--------|-----------------|
| N1 | **NVMe 协议层骨架**(命令组帧 + 队列状态机 + 完成处理), **纯仿真**验证 | 中-大 | 需 M.2 端行为模型(nvme 模型), 可先用行为桩 |
| N2 | **PRP/DMA 数据搬运**, 读数据→权重组 FIFO 校验 | 中 | 数据通路吞吐与背压 |
| N3 | **写路径**: 写命令 + 数据下发, 验证"更新缓存"闭环 | 中 | 写命令正确性/原子性 |
| N4 | **物理适配器 A**: 接 Gowin PCIe 硬核(AXI-Stream), 真机冒烟 | 视硬核 | T2 借 PC PCIe 槽先行(REFCLK/PERST#/config space→`lspci`); T1=RC 接金手指+转接卡 |
| N5 | **物理适配器 B**: 接自定义 SerDes 桥到板载 M.2 转接 | 大 | 仅当 T1 必须走板载 M.2 座才需要(该座=Q1 通用 SerDes, 非硬核) |
| N6 | ext4/file2lba 结果 → NVMe 命令对接, 绑板回环冒烟 | 中 | 138K 板 + NVMe SSD |

**前置未知(已查证解除)**: 板载 M.2 座=Q1 通用 SerDes 2 lane(原理图确认), PCIe 硬核=Q0 只到金手指。
结论: 硬核 N4 是主路(T1 用金手指+被动转接卡, T2 用 PC 槽), N5 仅在"必须用板载 M.2 座"时兜底。

### 11.6 验证策略

- N1-N3: 用 **NVMe 行为模型/桩**(模拟 M.2 端接受命令、回完成、供/收数据)在 iverilog
  纯仿真跑, 沿用"每阶段先编译+仿真通过再扩展" + sim.sh 回归追加 `nvme_*` 测试。
- N4-N6: 绑板回环冒烟(需 138K 板 + NVMe SSD), 和既有 SerDes 回环自测同法。
