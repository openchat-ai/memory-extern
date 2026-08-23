# 独立推理栈（脱离 llama.cpp）

> **版本 0.4** · 2026-08-23 · 状态：MAC 定标落地（128 预埋派 + 每 MAC ICG 门控）
> v0.2 架构确立；v0.3 RTL 骨架附录；v0.4 MAC 定标从"推荐"升级为"已决定"
> v0.2 核心架构确立；v0.3 新增附录 A：无 SRAM 架构的两块存储骨架（流式 FIFO / 寄存器驻留），可直接用于 RTL 开发
> 动机：产权审计（bandwidth-capacity-research.md §6.4）指出策略内核构建在
> llama.cpp 系引擎之上是最大灰色地带。本方向将其消解。
> v0.2 新增：无 SRAM 架构论证、云端四档产品线、dense/MoE 双口径、MAC 定标、HBM 结论、多模型分区。

## 一、目标

一个不依赖 llama.cpp 的独立 MoE 推理栈：
- 自有权重格式（流式友好，配合招一 NVMe 归零层）
- 自有 MoE 路由/expert 调度运行时（移植 sim_cache2 已验证的策略）
- 自有 GEMV 内核（pim/bench_q3_x86 结论：opt(f32)+4-way unroll）
- trace/预取作为一等公民而非 C++ 钩子补丁

## 二、核心架构结论（2026-08-23 全链推导收拢）

### 2.1 无 SRAM 架构 ⭐

**四档部署全部不需要 MB 级片上 SRAM。**

| 数据 | 住哪 | 原因 |
|---|---|---|
| 权重 | 外部 LPDDR5X，流式穿过 MAC | 容量太大，且只读 |
| 激活向量 x | **寄存器堆**（分布在 MAC lane 上，每 lane ~百字节）| GEMV 广播复用，驻留一次全程使用 |
| 输出累加 | 寄存器 → 写回 DRAM | 中间态小 |
| KV cache | 外部 LPDDR5X | 随用户数增长，外部容量便宜 |
| 流水缓冲 | **几十 KB 分布式 FIFO**（藏 DRAM 行激活抖动） | 唯一小件，非 SRAM 宏 |

收益：裸片从 ~169M T 缩到 ~70M T（~4mm²），成本再降近半；
且与 GPU/Cerebras/d-Matrix 的 SRAM 路线形成最本质的物理区别 = 成本优势来源。

边界条件：单流/浅 batch 零损耗；深 batch 高吞吐用**加 die**替代加深缓冲（线性堆叠 ✅）。

### 2.2 密集 vs MoE 双口径

| | Dense（Qwen3.8-27B @ Q3_K_S，12.57GB）| MoE（K3 @ mxfp4，25.83GB/token）|
|---|---|---|
| 每 token 读 | 全量 12.57GB（无稀疏折扣）| 25.83GB（实测落盘字节）|
| 每 token 计算需求 | **27 GOPS（计算受限！）** | ~114 GOPS（同样计算受限于 SIMD 宽度）|
| 单 die 吞吐 | ~2.5 t/s（Q3_K_S）/ ~10 t/s（mxfp4 重打包）| ~6.6 t/s |
| 扩展方式 | **加 MAC 数有效**（计算瓶颈主场）| 加 die 有效（取指受限）|

⇒ dense 场景 MAC 数才真正值钱（见 2.3）；MoE 场景颗数才是杠杆。

### 2.3 MAC 定标决策

考古：V1=34（4ch 68GB/s ÷2 配平）→ 升 8ch 后 ×2 = 68（理论配平 85.35 的八折，
EPYC 实测教训：理论带宽打八折）。实验验证：68 与 85 在脚本中 tok/s 完全一致——
模型盲区：脚本未建模"MAC 权重胃口上限"（68×2=136 < 171，浪费 20% 已购带宽）。

| 方案 | MAC 数 | 判定 |
|---|---|---|
| 保守派 | 80-85 | 当前 8ch 精确配平，收回 20% 浪费 |
| **预埋派（✅ 已采纳 2026-08-23）** | **128** | 已定案；RTL 骨架见 rtl/05_gemv/gemv_array_128.v（每 MAC 独立 ICG 门控）|

⚠️ >200 收益递减（SRAM 供给/NOC/良率开始顶）；INT4 SIMD 下 128 有真实吞吐余量。

### 2.4 HBM：三重锁定，不可"以后升级"

HBM PHY 硬宏 + 裸片边缘版图 + 2.5D 封装工艺——三者均需流片前锁定。
且 K3 容量受限场景下 HBM 经济性反而劣势（¥200+/GB vs LPDDR ¥90/GB，
容量占主导时 LPDDR 赢 26 倍）。唯一正路：chiplet 化（计算 die + 可换内存基座 die）=
第二代方向，第一代不做。

### 2.5 多模型部署：die 池化分区

224 颗分布式 die 的天然优势——物理分区硬隔离：

```
die 池 ├── 分区 A：K3-MoE（≥13 颗驻留 1.56TB）
       ├── 分区 B：27B-dense（4-8 颗）
       └── 分区 C：弹性池（按需扩缩）
NOC QoS 隔离，互不干扰；单 die 故障降级运行
```

多模型不需要专门硬件——容量分区 + 各自路由即可。

## 三、云端产品线阶梯（同一裸片，四种卡）

| 产品 | die 数 | 容量 | 聚合带宽 | K3 t/s | 27B t/s | 内存现价 | 对标 |
|---|---|---|---|---|---|---|---|
| 边缘盒 | 1 | 64 GB | 171 GB/s | 6.6 | ~13.6 | ¥0.6 万 | 主机 CPU 的 7 倍 |
| 工作组卡 | 4 | 256 GB | 683 GB/s | 26 | ~54 ✅ | ¥2.3 万 | ≥50 目标达成 |
| 部门节点 | 16 | 2 TB | 2.7 TB/s | ~106 | ~215 | ¥19 万 | H200 单卡性能，容量 14 倍 |
| 数据中心 | 224（4板）| 28.7 TB | 38 TB/s | 1,480 | ~5,900 | ¥260 万 | H200×12 舰队同价同速 |

*功耗按经济档估算（入门 ~28W/卡级递增到满血 ~6.5kW）；每 t/s 能效与 H200 打平至略优（DVFS 经济档 0.95x）*

## 四、零件清单

| 部件 | 现状 | 缺口 |
|---|---|---|
| GEMV 内核 | ✅ x86 最优实现已定 | NEON 对齐、查表融合 |
| 权重加载 | ⚠️ safetensors header 解析已有雏形 | 流式友好自定义格式 |
| MoE 路由/调度 | ✅ 策略层 Python 全部验证过 | 移植为 C |
| Attention/KV/sampling | ❌ 从零自扛 | 标准算法，工程量大但路径清晰 |
| trace/预取运行时 | ⚠️ 钩子版已在 research-cli 验证 | 升级为一等公民 |
| PCIe（远期） | ❌ 未开始 | 见 §六 |
| **GEMV die 的 2MB→小 FIFO SRAM** | **❌ 已决定：不设大 SRAM**（§2.1），仅需几十 KB 分布式 FIFO | 待 RTL |

## 五、开源依赖与致敬

| 基座 | 授权 | 本项目用法 |
|---|---|---|
| llama.cpp / SparkMoE fork | MIT | 研究期宿主与方法论试验场；经验将反哺独立栈 |
| Wavious wddr RTL | Apache-2.0/GPL 混合 | PHY 数字部分基座（rtl/10_phy_final）|
| Ibex (lowRISC) | Apache-2.0 | MCU 子系统 |
| verilog-pcie（计划采用） | MIT | 远期 PCIe 协议层 |
| 上游 sim_cache.py 作者 | —— | 方法论对话起点；其正确结论已定损收录 |
| 思想参考 | —— | MoE-Infinity（缓存/预取策略）、d-Matrix Corsair（分层架构商业验证）、FlashMoE（边缘 SSD 卸载）|

## 六、顺序建议

```
1. 独立模拟器/运行时（当前进行中，权重机）
2. GEMV die 内控制器（复用 mini-DFI 经验；含几十 KB 流式 FIFO）
3. PCIe 最后：协议层抄 verilog-pcie；PHY 又是墙——
   备选=招二寄生术（宽并口方言+桥片代言），不做 Gen3+ SerDes
```

## 七、开放问题

| # | 问题 | 影响 |
|---|---|---|
| O1 | mxfp4 解包是否需要额外逻辑周期（1.82bit 非整对齐） | t/s 折扣系数 |
| O2 | 多 die 间路由同步开销（93 层 × 每层跨片通信） | 实际 t/s 再打折 |
| O3 | 无 SRAM 下权重预取 FIFO 的最小深度与流水线断流风险 | 小档稳定性 |
| O4 | Qwen3.8-27B 若以 Q3_K_S 部署的反量化开销占比 | dense 产品实际 t/s |

## 八、厂商触达状态

| 厂商 | 渠道 | 状态 |
|---|---|---|
| 芯动科技 | 邮件已发（首封无回音 → 二击邮件待规格书完成后发送）| 🔄 |
| 并行询价 | 灿芯（中芯系）、芯耀辉、牛芯 | 待启动 |

详见 `notes/rfq-prep-plan.md`（交付物七项计划）。

## 附录 A：存储骨架 RTL（无 SRAM 架构的实现件）

> 两块代码均为完整可综合模块——纯 RTL 直写，无需 SRAM 编译器或代工厂宏。
> 综合工具会将此规模（几十 KB）的 logic 数组自动映射为触发器/锁存器阵列。

### A.1 流式 FIFO（权重预取缓冲，藏 DRAM 延迟抖动）

```systemverilog
module stream_fifo #(parameter DEPTH=256, WIDTH=128) (
    input  wire         clk, push, pop,
    input  wire [WIDTH-1:0] wdata,
    output wire [WIDTH-1:0] rdata,
    output wire         full, empty
);
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [$clog2(DEPTH)-1:0] wp, rp;

    assign empty = (wp == rp);
    assign full  = ((wp + 1) % DEPTH) == rp;
    assign rdata = mem[rp];

    always @(posedge clk) begin
        if (push) mem[wp] <= wdata;
        if (push && !full) wp <= wp + 1;
        if (pop  && !empty) rp <= rp + 1;
    end
endmodule
```

实例化建议：权重预取用 DEPTH=256 × 128bit（4KB/方向，双缓冲×8 足够藏行激活抖动）。

### A.2 激活向量寄存器驻留（每条 MAC lane 的 x 分片）

```systemverilog
// K3: hidden=7168 ÷ 68 lanes ≈ 106 元素/lane × bf16
logic [15:0] x_local [0:105];    // 每 lane ~212 B，纯触发器

// 权重流过时本地配对乘加（零 DRAM 重取、零 SRAM 占用）
// 加载：层切换时从 LPDDR 预取一次（14KB 全向量，广播写入各 lane 分片）
```

### A.3 综合边界说明

| 数组规模 | 综合结果 | 说明 |
|---|---|---|
| ≤ 几十 KB | 触发器/锁存器阵列 ✅ | 本架构全部存储在此区间 |
| MB 级 | 工具报警，要求换 memory macro | 已通过"不设大 SRAM"决策规避 |

---

## 变更历史

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-08-23 | 初稿：脱离 llama.cpp 决策立项；零件盘点；依赖致敬表 |
| 0.2 | 2026-08-23 | 核心架构确立：无 SRAM（寄存器驻留+KB FIFO）；密集/MoE 双口径；MAC 定标 68→128 预埋；HBM 三重锁定不可后升级；多模型 die 池化；四档产品线阶梯表；开放问题 O1-O4 |
| 0.3 | 2026-08-23 | 附录 A：流式 FIFO 与寄存器驻留 x 分片的 RTL 骨架（可直接开发）+ 综合边界说明 |
| 0.4 | 2026-08-23 | MAC 定标落地：128 预埋派 + 每 MAC ICG 门控；RTL 骨架 gemv_array_128.v 新增；calc_performance.py 同步 128 口径 |
