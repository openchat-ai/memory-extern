# GEMV 芯片性能计算公式

**日期：2026-08-20**
**原则：所有数字必须可追溯到公式。以 `pim/calc_performance.py` 为准。**

---

## 一、单芯片规格（8ch LPDDR5X）

```
MAC 数 = 68
时钟频率 = 1.0 GHz
每 MAC 每周期处理 = 4 bytes（2B 权重 + 2B 激活，bf16）

计算带宽 = 68 × 1.0 × 4 = 272 GB/s
权重带宽需求 = 68 × 1.0 × 2 = 136 GB/s（仅 DRAM）
内存带宽 = 8 × 10667 × 16 / 8 / 1000 = 170.7 GB/s
内存容量 = 8 × 16GB = 128 GB
SerDes = 4 lanes × 100 Gbps = 50 GB/s/chip
功耗 = 30W
成本 = ¥1,174（含封装+DRAM）
```

---

## 二、内存带宽公式

所有内存带宽统一公式计算（无硬编码）：

```
DRAM 带宽 (GB/s) = channels × mt_s × bus_bits / 8 / 1000
```

示例：
- LPDDR5X-8ch: 8 × 10667 × 16 / 8 / 1000 = 170.7 GB/s
- LPDDR5X-4ch: 4 × 10667 × 16 / 8 / 1000 = 85.3 GB/s
- HBM3-1stack: 1 × 6400 × 1024 / 8 / 1000 = 819.2 GB/s
- HBM3-2stack: 2 × 6400 × 1024 / 8 / 1000 = 1638.4 GB/s

---

## 三、瓶颈分析

```
GEMV 每 MAC: 2B 权重(DRAM) + 2B 激活(SRAM) = 4B
权重从 DRAM 读取: 2B/MAC
激活从 SRAM 读取: 2B/MAC（已加载）

权重带宽需求 = MAC_COUNT × CLOCK_GHZ × 2 = 136 GB/s
DRAM 带宽 = channels × mt_s × bus_bits / 8 / 1000

如果 DRAM < 136 GB/s → DRAM 瓶颈 → MAC 有空闲，可以降频
如果 DRAM > 136 GB/s → 计算瓶颈 → MAC 满载，不能降频
```

---

## 四、性能公式

### Dense 模型

```
effective_bw = min(compute_bw, dram_bw)
compute_bw = n_chips × 272 GB/s
dram_bw = n_chips × dram_bw_per_chip

tok/s = 1 / (layers × weight_gb / effective_bw)
```

### MoE 模型（如 K3）

```
tok/s = 1 / (layers × activated_gb / effective_bw)
activated_gb = activated_params × bytes_per_param
effective_bw = active_chips × dram_bw_per_chip
active_chips = min(experts_active × chips_per_expert, n_chips)
```

**关键变量：`active_chips`（多少颗芯片在工作）**

K3 有 896 expert，16 active/token。224 芯片时：
- 每芯片存 896/224 = 4 个完整 expert
- 激活 16 expert → 16 颗芯片工作
- 有效带宽 = 16 × 171 = 2,731 GB/s
- tok/s = 1 / (93 × 52 / 2,731) = **0.56 tok/s**

**如果 expert 能拆分到多颗芯片：**
- 每 expert 分布到 224/16 = 14 颗芯片
- 激活 16 expert × 14 芯片 = 224 芯片全部工作
- 有效带宽 = 224 × 171 = 38,231 GB/s
- tok/s = 1 / (93 × 52 / 38,231) = **7.91 tok/s**

### All-reduce 通信

```
Ring all-reduce 时间 = (p-1)/p × msg_bytes / total_serdes_bw
msg_bytes = hidden_dim × 2 (bf16)
K3: 14.3 KB / 11,200 GB/s = 1.28 μs（可忽略）
```

---

## 五、H200 对比公式

```
h200_tok/s = 1 / (layers × activated_gb / h200_bw)
h200_bw = 4,800 GB/s（单卡）
cost_ratio = our_cost / h200_cost
```

H200 单卡 4,800 GB/s，K3 每 token 读 52 GB：
- 单卡 H200: 93 × 52 / 4,800 = 1.00 s/token = 1.0 tok/s
- 8 卡 H200: 93 × 52 / 38,400 = 0.126 s/token = 7.9 tok/s

---

## 六、常见错误

| 错误 | 正确 |
|---|---|
| BYTES_PER_MAC = 2 | BYTES_PER_MAC = 4（bf16: 2B权重 + 2B激活） |
| COMPUTE_BW = 136 GB/s | COMPUTE_BW = 272 GB/s |
| 权重需求 = 68 GB/s | 权重需求 = 136 GB/s |
| effective_bw = dram_bw | effective_bw = min(compute_bw, dram_bw) |
| 8ch 是内存瓶颈 | 8ch (171 GB/s) > 136 GB/s → 计算瓶颈 |
| 4ch 是计算瓶颈 | 4ch (85 GB/s) < 136 GB/s → DRAM 瓶颈 |
| 硬编码 HBM 带宽 | 统一公式计算：channels × mt_s × bus_bits / 8 |

---

## 七、性能数据（28 芯片，LPDDR5X-8ch）

| 模型 | 有效BW | tok/s | vs H100 |
|---|---|---|---|
| Llama-7B bf16 | 4,779 GB/s | 10.67 | 1.43x |
| Llama-70B bf16 | 4,779 GB/s | 0.43 | 1.43x |

| 内存 | 有效BW | 7B tok/s | vs H100 |
|---|---|---|---|
| LPDDR5X-8ch | 4,779 GB/s | 10.67 | 1.43x |
| LPDDR5X-4ch | 2,389 GB/s | 5.33 | 0.71x |
| HBM3-1stack | 7,616 GB/s | 17.00 | 2.27x |
| HBM3-2stack | 7,616 GB/s | 17.00 | 2.27x |
