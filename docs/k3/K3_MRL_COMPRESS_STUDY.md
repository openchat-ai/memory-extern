# K3 trunk「不解压可用」最大压缩研究与 Matryoshka 嵌套格式

> 2026-09-10 · 拆 trunk 顺带研究 · 基于 `/mnt/nvme/trunk_p128t_full`(MXFP8_E8M7_128, 55.6GB)
> 与 WeMM-Embedding (tencent/wemm-embedding) 的 Matryoshka Representation Learning 思想对照。

## 0. 问题

trunk 按 93 层拆成独立切片(`tools/trunk2layers.py`, 已落地)后, 每层 v1=632MB / v2=419MB。
问: 能否比 MXFP8(8.0625 bit/elem) 更小, 且**不解压即可用**(硬件直接吞编码字节)?

**约束(否决的路径):**
- zlib / Huffman / 算术编码: 必须解压, 违反"不解压可用"。且 byte.Ent 6.9~7.2 bit(已测), 上限 ~13%。
- 对称砍位(MXFP8→MXFP4「一次性全量 4bit」): 实测能量 error 100%、argmax 0%(E2M1 值域对权重量化太狠, 见 §2)。

## 1. Matryoshka 思想映射

WeMM: 一个高维 embedding 的**前缀子向量任意维度独立可用**, 推理按预算 truncate(64/128/.../4096),
2B@256 维仍保留 98.7% 全维性能。不需要重训、不需要两张表。

映射到权重: 一个层文件内**嵌套两个量化层** —— 粗码字层(base) + 残差增补层(resid):

```
layer_004.bin(单文件):
  [base  : int8 scale ×ngrp + 4bit E2M1 码 ×cols/2]   ← 只读前 ~50% 字节即得粗权重(≈4.06 bit/elem)
  [resid : scale + 稀疏残差存储]                         ← 追加读 = 补精
```

硬件读 nibble 直接乘(同 `k3_matmul_mxfp4` 模式), 不解压。低成本档 = 只读 base(≤28GB trunk);
高保真档 = 读完。**一份文件, 两档精度, 按读取量定档** —— 这就是权重的 Matryoshka。

## 2. 实测矩阵(单张量, routed_expert_up_proj [7168,3584] / q_proj [12288,7168])

统一标尺: 解码回 f32 vs 源 MXFP8(解回 BF16 视作真值), 高斯输入 argmax 命中率。

### 一次性全量 4bit(对称砍, 之前误判) vs 正确量化:

| 方案 | bit/elem | energy | SNR | argmax | 结论 |
|---|---|---|---|---|---|
| MXFP8 现状 | 8.062 | 0% | ∞ | 100% | 基准 |
| **base4bit(E2M1, 正确 per-128 对数归一)** | 4.062 | 15.6% | 16.1 dB | 62.5% | "全砍4bit"≠105%错, 但 argmax 62.5% 仍不可用 |

> 教训: 之前"4bit 全废"是**实现 bug**(把值域压到 [0,1) 再取 E2M1)。正确做法是 per-128
> 组内 `2^⌊log2(max/6)⌋` 对数归一化到 E2M1 值域 [0,6] → 能量 15.6% / argmax 62.5%。

### Matryoshka(嵌套残差) —— q_proj 张量实测:

| 残差档 | bit/elem | trunk 口径 | energy | argmax | 备注 |
|---|---|---|---|---|---|
| 0%(纯 base) | 4.06 | 28.5 GB | 17.4% | 68.8% | 粗读, -50% |
| +6.25% 残差 | 5.39 | 37.8 GB | 8.7% | 81.3% | -33%, 中等 |
| **+12.5% 残差** | **6.98** | **49.0 GB** | **6.6%** | **93.8%** | **-12%, 高保真** |
| +50% 残差 | 11.3 | 79 GB | 3.9% | 93.8% | 收益饱和 |
| +100%(全残差) | 24.2 | - | 0% | 100% | 无损(redundant, 不推荐) |

(u_proj 张量: 同规律, +12.5% 档 5.07 bit/elem / 85.9%; 双张量一致)

## 3. 关键结论

1. **"不解压可用 + 最大压缩"的甜点 = base4bit + 稀疏残差 ~12.5%**:
   全 trunk ≈ 49 GB(vs 55.6, **-12%**), energy 6.6%, argmax 93.8%。
   若只求检索/草稿档, base4bit = 28.5 GB(**-49%**), 68.8% argmax。
2. **argmax 93.8% 仍不足 K3 生成可靠性**。98%+ 需: 残差档提到 25%(5.2% energy, 但 argmax 仍 87.5%
   —— 说明 argmax 命中对残差选择点敏感, 不是单调)。
3. **2 档分级是 MRL 真正价值**: 板上 1GB 只放"当前层档"时, 低成本槽可用 base(28.5GB 全放 NVMe)、
   高保真 pass 再补 resid。解码在同一内核路径(4bit nibble), 不解压。
4. **后续(未封锁)**: argmax 保真目标需**真实隐藏态分布**测试(非高斯)。板子预填/生成为真实 x,
   logits 对比沿用 rel<10% + argmax SAME 基线(board-1g §9)。

## 4. 产物

- `tools/trunk2layers.py` — 93 层拆片(已跑, 53GB → /mnt/nvme/trunk_layers_out/)
- `tools/compress_probe.py` — 单张量方案矩阵(A/E/F/G/H/I) 
- `tools/mrl_sweep.py` — 残差占比 0..100% 扫描
- 本次实测: layer4 q_proj/u_proj 双张量交叉验证, 结论一致。

## 5. 与 WeMM 的异同

- 同: Matryoshka 分级思想(前缀/低档独立可用, 按预算消费)。
- 异: WeMM 是训练时让子向量都有效; 权重是 Frozen(不能重训), 故用**量化残差嵌套**近似
      MRL: base 不是独立量化, 而是「全量精度的粗前缀」+ 残差补全。
- 若未来有预算微调(K3 权重冻结, 短期不可行), 可训 MRL 式多档 loss 面 → 真·任意档截断。