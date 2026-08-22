# GEMV 加速芯片市场调研

> ⚠️ 本文中 V1 的芯片参数为旧口径（34 MAC / 68 GB/s / 16GB），已更新为 **68 MAC / 171 GB/s / 128 GB**（8ch LPDDR5X）。竞品与市场数据仍有效。以 `pim/calc_performance.py` 为准。
>
> 2026-08-20 三轮调研汇总。用途：验证 V1（LPDDR5X DRAM 带宽 + 专用 GEMV 阵列 + 边缘/嵌入式推理）赛道是否成立、数字是否可复算、差距在哪里。
>
> **先纠正一个定位错误**：V1 **没有用 SRAM 存权重**。V1 = 全直焊 LPDDR5X（4 颗/芯片，16GB）DRAM 带宽路线，2MB SRAM 仅作片上搬运缓冲（R6 控制器，double-buffering）。Groq/Cerebras 的 SRAM 存权重路线与 V1 无关。
>
> **三条技术路线**：
> 1. **SRAM 存全部权重**（Groq/Cerebras，150 TB/s 级）→ V1 未选
> 2. **DRAM 带宽 + 外部存储**（H100 / Vera Rubin / Tenstorrent / 边缘 NPU）→ **V1 在此路线**
> 3. **存内计算 CIM/PIM**（Samsung HBM-PIM、SK Hynix AIM、AMMA、AiF、PIM-DIMM）→ V1 不选 CIM；PIM-DIMM 是独立互补路线，与 V1 不冲突

## 0. 核心公式与自检

- **tokens/s ≈ 内存带宽 ÷ 模型字节数**（decode 受带宽限制）
  - 7B bf16 = 14GB → 68 ÷ 14 = **4.9 tok/s**（与 accelerator-plan 完全一致）
  - 7B INT4 = 3.5GB → 68 ÷ 3.5 ≈ **19 tok/s**（**仅带宽墙**，见下方算力墙更正）
- **LPDDR5X x64 双 device 标准带宽 = 68 GB/s**（SemiEngineering）→ V1 的 68 GB/s 是行业标准值，非拍脑袋
- **差距信号**：手机 Exynos 2600（LPDDR5X 85.6 GB/s）实测 7B Q4 = 8-15 tok/s → **V1 不支持 int4 会比手机慢 2-3×，int4 支持应为 P1**

### ⚠️ 算力墙更正（2026-08-20 补洞）

> **之前的 int4 带宽墙计算（19 tok/s）是错的**：那只算了带宽墙，没算算力墙。V1 的 34 MAC 是**配平设计，不是富余设计**——MAC 数是从带宽倒推的（34 MAC × 2B × 1GHz = 68 GB/s）。

| 精度 | 带宽墙 | 算力墙 | 实际 tok/s |
|------|--------|--------|-----------|
| bf16 | 68÷14 = 4.9 | 34÷7 = 4.9 | **4.9**（双墙同时到） |
| int4 | 68÷3.5 = 19.4 | 34÷7 = **4.9** | **~5~10**（MAC 次数不变，算力墙锁死；若阵列支持 int4 子字并行翻倍也就 9.7） |

- **根因**：int4 只减权重的字节数（带宽），不减 MAC 次数（7B 参数/token 的乘加还是那么多）。带宽墙拆了，墙立刻塌向算力墙。
- **V1 真实处境 = compute-bound（或恰好配平），不是 bandwidth-bound**：68 GB/s 只是"够 34 MAC 吃"的配平带宽，不是冗余带宽。int4 下带宽只吃到 17-34 GB/s，从未吃满。
- **业界带宽口径成立的前提是算力富余**：H200/Cerebras/H20 都是算力过剩、带宽不足，加带宽立竿见影（H200 换 HBM3e +43% 带宽 → 推理 +60-80%）。V1 没有这个富余。
- **int4 的真实收益 = 省 DRAM 容量（3.5 vs 14GB）和功耗，不提速**。定位是"装得下 + 省电"，不是"追上手机"。
- **提速唯一正路 = 加 MAC**：多芯片每颗 34 MAC 同步翻倍（14 颗 = 476 MAC ÷ 7B = 68 tok/s），瓶颈从没离开过 MAC。

## 1. 第一轮：全行业格局（间接参考）

### SRAM 存权重巨头（与 V1 路线不同，仅证赛道热度）

| 玩家 | 关键事实 | 甄别备注 |
|------|---------|---------|
| Groq LPU | 500MB SRAM、150 TB/s；2025-12 被 NVIDIA 以 $20B 收购，并入 Vera Rubin 做 decode 侧车（LPX 机架 256 颗/128GB/40 PB/s，Q3 2026 出货） | 大厂背书：NVIDIA 用 $20B 验证"SRAM decode 加速器"独立价值 |
| Cerebras WSE-3 | 44GB SRAM、21 PB/s；AWS Bedrock + OpenAI 合同（$10B / 750MW） | — |
| Etched Sohu | TSMC N4P、144GB HBM3E，宣称 500K tok/s（Llama 70B），$1B+ 订单，**0 交付** | 宣称未出货验证 |
| d-Matrix Corsair | DIMC 存内计算，GPU 协处理器 | 见第二轮 |
| Taalas HC1 | per-model 硅，2026-08 被 AMD 收购 | 已被巨头收编 |
| OpenAI×Broadcom Jalapeño | reticle 840mm²、8 HBM、decode 专用，原型 Q4 2026 | 大厂自研信号 |
| PIM/PNM 存储厂 | Samsung HBM2-PIM / SK Hynix AIM / AMMA / AiF | 验证近存方向 |

**信号**：NVIDIA 收购 Groq 验证了"异构推理 = GPU prefill + SRAM decode"；HBM4 缩小差距；推理成为巨头必争之地。

## 2. 第二轮：V1 对标轮（DRAM 带宽路线）

| 玩家 | 配置 | 与 V1 的关系 |
|------|------|-------------|
| Qualcomm AI200 | 768GB LPDDR/卡，数据中心推理，2025-10 | 大厂验证 LPDDR 容量路线 |
| Qualcomm AI250 | 2027，近存 >10× 有效带宽 | 验证近存演进方向 |
| AMD Strix Halo | 256-bit LPDDR5X，256 GB/s，128GB | 同路线更高带宽 |
| Apple M4 Max | 512-bit LPDDR5X MoP，546 GB/s | MoP 封装近存化 |
| NVIDIA RTX Spark | Blackwell + Grace + LPDDR5X 128GB 统一内存 | 大厂进 LPDDR 推理 |
| Tenstorrent Blackhole | 32GB GDDR6、512 GB/s、300W、$1399、120 Tensix + 16 RISC-V、180MB SRAM | 开放/低成本对标 |

**学术旁证**：LP-Spec（arXiv 2508.07227）LPDDR PIM 移动端推测解码，7B 比 RTX 3090 好 **415× EDP** → 验证 PIM-DIMM 独立路线有价值。

## 3. 第三轮：小公司参与情况

### 与 V1 最接近的异质加速器

| 公司 | 融资/状态 | 技术 | 甄别备注 |
|------|----------|------|---------|
| d-Matrix（Corsair） | 累计 ~$500M，$2B 估值（微软 M12 投资）；2026-06 全面量产并出货 | **SRAM 存内计算 chiplet + LP-DDR5**（TSMC N6、Alchip 代工，避开 HBM）；GPU prefill + Corsair decode；SquadRack 整机；宣称 Llama 70B 30,000 tok/s | "10x 更快 / 5x 省电 / 3x 便宜"为自家宣称；Gimlet Labs 委托测试背书（24s→<2s），非独立评测。**验证了"LPDDR decode 专用 + SRAM 缓冲"商业可行且正在大规模出货** |
| FuriosaAI（RNGD） | 2026-01 拟再融 $500M；2026-05 TSMC 5nm + CoWoS 量产；曾拒 Meta $8 亿收购；拟 2027 IPO | Tensor Contraction Processor；自称 2.25× GPU 能效；LG AI Research 采用跑 EXAONE；2026-07 扩欧洲（Equinix LS2）+ 斯德哥尔摩 15MW 推理 DC | 韩国国家队色彩（KDB/IBK 参投） |
| Etched | 2026-06 出隐身后累计 $800M；2026-07 再融 $300M @ $10.3B | Sohu 专用 transformer ASIC | 估值最高的小公司，0 出货 |
| SambaNova | $1B Series F @ $11B（2026-07） | 数据流 RDU | — |
| OLIX | $312M @ $3.3B（2026-08） | 光子推理 + SRAM + 确定性编译器调度 | 光子路线早期 |
| Tensordyne | 3nm Napier tape-out（2026-06） | Sunnyvale + Munich | — |
| Tenstorrent | Blackhole 已开卖 | 见第二轮 | — |

### 存内计算/边缘（中国为主）

| 公司 | 融资/状态 | 技术 | 甄别备注 |
|------|----------|------|---------|
| 后摩智能 | Pre-A 3 亿（2021，启明领投）；鸿途 H30 256TOPS/35W 智驾；二代漫界 M50 2025Q4 量产 | 大算力 CIM；宣称单卡 7B/8B >25 tok/s、被动散热 | 宣称值待独立验证；CIM 路线，仅作基准参考（**int4 端侧门槛佐证**） |
| EnCharge AI | — | 模拟存内计算 | 模拟 CIM 良率风险 |
| 清华系存算一体公司 | 天使轮融资中（2026） | transformer 加速 + 存算一体 | — |
| Axelera AI | 2026-02 $250M 轮，累计 $450M | 数字存内计算 D-IMC；Metis 214 TOPS/16W/12nm；Titania chiplet 预计 2028 | 推理市场 $106B(2025)→$255B(2030) 引用 |
| Mythic | 2025-12-17 $125M 超募 | 模拟 APU，宣称 100× 能效 | CEO Taner Ozcelik；模拟路线风险同 EnCharge |
| EdgeCortix | — | SAKURA 60 TOPS/<10W/7nm | 边缘均衡档 |
| SiMa.ai | — | MLSoC 50 TOPS/5W/16nm | 嵌入式视觉 |

### 市场结构性事实（边缘推理深度报告，知乎 2026-06-24）

- 2024 全球推理任务占边缘 AI 芯片应用 **99.8%** → 边缘只要高效推理，不要训练
- 三层市场：高性能（50-300 TOPS，Jetson AGX Orin 275T）、均衡（10-60 TOPS，Hailo/SAKURA，**竞争最激烈但机会最多**）、超低功耗（<10 TOPS，Coral/Kneron）
- **2026 分水岭**：从 TOPS 竞赛转向 TOPS/W、TOPS/$、每次推理成本
- 机会窗口：工业"刚刚好"档位（10-30 TOPS、5-10W、<$30 芯片成本）
- 设计优先级：P0 场景唯一 + 能效 ≥5 TOPS/W + SDK 先行；P1 片上 SRAM 最大化 + 无外部 DRAM（IoT）；P2 安全启动 + 公开 MLPerf 数据
- 趋势：chiplet 下沉边缘（UCIe）、端侧 1B-7B 本地推理、RISC-V 崛起（2028 约 30% 新设计）

## 4. 对 V1 的结论

1. **赛道对**：LPDDR 推理路线被 Qualcomm/AMD/Apple/NVIDIA/Tenstorrent 大厂占据，且 d-Matrix 用"SRAM CIM + LP-DDR5"同路线大规模出货 → V1 方向获背书
2. **数字对**：68 GB/s = LPDDR5X x64 双 device 标准带宽；4.9 tok/s 可由公式复算（68÷14）；手机实测佐证量级
3. **差距怎么改**：
   - **int4 量化支持 = P1**（否则比手机慢 2-3×，后摩 M50 端侧 >25 tok/s 进一步挤压；int4 省 DRAM 容量和功耗，但**不提速**——算力墙锁 ~5-10 tok/s，见第 0 节更正）
   - **近存/演进**：LPDDR6、MoP 封装、近存 CIM（Qualcomm AI250、Apple M4 Max MoP、d-Matrix、LP-Spec）→ V1 需跟踪并预留演进路径（LPDDR6 带宽翻倍、近存缩小有效带宽差距）
   - 多芯片扩展是提升 tok/s 的正路（**每颗芯片把带宽和 MAC 一起翻倍**，V1 已规划）
4. **赛道拥挤度上升**：NVIDIA 收 Groq、AMD 收 Taalas、微软投 d-Matrix、Meta 想收 FuriosaAI → 巨头在收编小公司，V1 需靠成本（14nm + 国产供应链）和聚焦场景差异化

## 5. 数据可信度标注

| 数据 | 可信度 | 来源 |
|------|--------|------|
| 68 GB/s LPDDR5X 标准 | 高 | SemiEngineering 规格 |
| Qualcomm/AMD/Apple/NVIDIA 产品线 | 高 | 官方发布 |
| d-Matrix "10x/5x/3x" | 中（厂商宣称） | d-Matrix + Gimlet Labs（委托测试） |
| Etched 500K tok/s | 低（0 出货） | 厂商宣称 |
| 后摩 M50 >25 tok/s | 中（待独立验证） | 厂商发布会 |
| 边缘市场三层/机会窗口 | 中（行业报告引用） | 知乎 2026-06-24 深度报告 |