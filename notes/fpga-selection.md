# FPGA 选型：符合要求的开发板

> 2026-08-20 调研。

## 需求

| 需求 | 最低要求 | 理想 |
|------|---------|------|
| 内存 | DDR4 ≥8GB | DDR5/LPDDR5 |
| 带宽 | ≥50 GB/s | ≥100 GB/s |
| 逻辑 | ≥200K LUT | ≥500K LUT |
| PCIe | Gen3 x8 | Gen4 x16 |
| 价格 | ≤¥5 万 | ≤¥15 万 |

## 推荐方案（按性价比排序）

### ⭐ 方案 1：Alinx AXU5EV（¥5000-8000）

| 项 | 规格 |
|---|------|
| FPGA | Xilinx Zynq UltraScale+ XCZU5EV |
| 逻辑 | 256K LUT |
| DSP | 1728 |
| 内存 | DDR4 **4GB**（板载） |
| 带宽 | ~34 GB/s |
| PCIe | Gen2 x4（通过 PS） |
| 价格 | **¥5000-8000**（淘宝） |
| 优点 | 最便宜，中文文档多，社区大 |
| 缺点 | DDR4 只有4GB，跑不了35B（18.3GB） |

**适合**：验证7B模型（14GB bf16 / 4GB Q3_4bit）

### ⭐ 方案 2：Xilinx VCK190（¥3-5 万）

| 项 | 规格 |
|---|------|
| FPGA | Xilinx Versal AI Core VC1902 |
| 逻辑 | 900K LUT |
| DSP | 4000+ |
| 内存 | DDR4 **8GB**（DIMM 插槽） |
| 带宽 | ~50 GB/s |
| PCIe | Gen4 x16 |
| 价格 | **¥3-5 万** |
| 优点 | Versal 架构，DDR5 控制器内置 |
| 缺点 | 停产，二手市场 |

### ⭐ 方案 3：Alinx AXU15EV（¥8000-12000）

| 项 | 规格 |
|---|------|
| FPGA | Xilinx Zynq UltraScale+ XCZU15EG |
| 逻辑 | 600K LUT |
| DSP | 3600 |
| 内存 | DDR4 **8GB**（板载） |
| 带宽 | ~50 GB/s |
| PCIe | Gen3 x4 |
| 价格 | **¥8000-12000** |
| 优点 | 逻辑够用，DDR4 8GB |
| 缺点 | DDR4 带宽有限 |

### 方案 4：BaiClone / 紫光同创（¥3000-8000）

| 项 | 规格 |
|---|------|
| FPGA | 紫光同创 PGL22G / PG2T39 |
| 逻辑 | 200K-400K LUT |
| 内存 | DDR3/DDR4 |
| 价格 | **¥3000-8000** |
| 优点 | 国产，便宜 |
| 缺点 | 生态差，文档少 |

### 方案 5：Altera Agilex 5 E-Series（¥5-10 万）

| 项 | 规格 |
|---|------|
| FPGA | Intel Agilex 5 E-Series |
| 逻辑 | 65K-150K LE |
| 内存 | DDR5/LPDDR5 |
| 带宽 | ~50 GB/s |
| 价格 | **¥5-10 万** |
| 优点 | 支持 DDR5/LPDDR5 |
| 缺点 | 贵，生态不如 Xilinx |

### 方案 6：Altera Agilex 7 M-Series（¥15-30 万）

| 项 | 规格 |
|---|------|
| FPGA | Intel Agilex 7 M-Series |
| 逻辑 | 1M+ LE |
| 内存 | **HBM2e**（封装内）+ DDR5 |
| 带宽 | **460 GB/s**（HBM2e） |
| 价格 | **¥15-30 万** |
| 优点 | HBM2e 带宽够 |
| 缺点 | 太贵 |

## 结论

| 方案 | 能跑模型 | 价格 | 推荐 |
|------|---------|------|------|
| AXU5EV | 7B Q3 | ¥5K | ✅ 入门 |
| AXU15EV | 13B Q3 | ¥10K | ✅ 性价比 |
| VCK190 | 35B Q3 | ¥3-5万 | ⭐ 最佳 |
| Agilex 5 | 35B Q3 | ¥5-10万 | ⚠️ 贵 |
| Agilex 7 | 35B bf16 | ¥15-30万 | ❌ 太贵 |

**建议**：先买 AXU5EV（¥5000）验证7B，确认架构可行再升级。
