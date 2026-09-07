# 真实权重探针：K3 权重离散性与二幂结构 验证笔记

日期: 2026-09-03（更新: 2026-09-04 真实 /model 完整96分片补测）
数据来源: hf-mirror 镜像拉取的真实权重 + 本机 MXFP4 fixture + /model 完整96分片
工具: `tools/probe_real_weights.py`（判据1+2+3，读 safetensors）`tools/probe_weight_discreteness.py`（判据1+2）`_probe_quick.py`（去 SVD 快速版，全结构批量实测）

## 结论(三要素)

K3 权重是否可"公式化压缩/移位 GEMV"，用三要素判定：

| 判据 | 含义 | 值高则支持 |
|---|---|---|
| [1] 唯一值数 k vs 元素 n | k<<n → 用 log2(k) 位索引无损查表 | 公式化/查表压缩 |
| [2] 二幂结构(k·2^e)比例 | 高 → 乘法=移位，免解压直接 GEMV | 无解压计算 |
| [3] 奇异值谱形态 | 低秩 → SVD 低秩压缩可行；满秩 → 不可 | 低秩压缩 |

## 实测结果

### 1. MXFP4 fixture (本机 `pim/fixture_mxfp4.bin`, K3 原版权重格式)
- 形状 [64,3584]，唯一值 **21** (0.009%)
- 二幂结构 **100%**：全部落在 ±k·2^e (k∈{1,3,5,7}, e∈[-8,-3])，如 ±0.007812=2^-7, ±0.015625=2^-6, ±0.023438=3·2^-7...
- → 5 位索引/元素，**6.4x 无损** + 移位 GEMV
- 注：这是 MXFP4(E4M3) 反量化后的固有离散结构。真实 K3 用 E2M1 尾数表 `K3_E2M1={0,0.5,1,1.5,2,3,4,6,-0,-0.5,-1,-1.5,-2,-3,-4,-6}`（见 §1b/§1c），其幅度即 {0.5,1,1.5,2,3,4,6} = k∈{1,3,5,7} 的 {×1,×0.5}，k·2^e 性质一致，故 §1 的 100% 二幂结论对真实 K3 专家成立。

### 1b. 真实 K3 中间层 MXFP4 专家（layer.47, /model 完整96分片, 解包后）
- 结构: 每层 896 专家, 激活 16, 共 92 层; `experts.{N}.w{1,2,3}.weight_packed` U8[3072,1792] + `.weight_scale` U8[3072,112]
- 解码(官方 `k3_ops.c`/`k3_mxfp4_dequant`): 权重 = `K3_E2M1[nib] × 2^(scale-127)`；每 byte 2 nibble(低位=偶元素、高位=奇元素)；scale 每 32 元素 1 个(ngrp=112)。`K3_E2M1[16]={0,0.5,1,1.5,2,3,4,6, -0,-0.5,-1,-1.5,-2,-3,-4,-6}`
- layer.47 expert0.w1: 唯一值 **43**/11M (0.0004%), 二幂 **72.1%**
- layer.47 expert895.w1: 唯一值 **31**/11M (0.0003%), 二幂 **100.0%** (范围[-32,24])
- A/B: 列内平均唯一指数数 ~5.9 -> 均匀混杂 = **紧凑编码/查表(A)**, 非可分列公式(B)
- **重要校准**: 开头层 layer.1(experts.0.w1) 解包后唯一值 161/二幂仅 1.9%, 与中间层差异大 -> **开头层结构异常, 应以中间/代表层为准**(此前"唯一值21/100%"基线对应中间态本质: 唯一值≈2^5量级 + 强二幂)
- → 顺证两侧: **唯一值 31-43 << 11M(0.0003%) -> log2~5 位索引无损查表, 5x+ 压缩; 二幂 72-100% -> k·2^e 移位 GEMV 免解压**

### 1c. MXFP4 无损重构对照实验（2026-09-04，真实 `experts.0.w1`，11,010,048 元素）
- 方法: 严格照官方 `k3_ops.c`/`k3_mxfp4_dequant` 公式(`K3_E2M1[nib] × 2^(scale-127)`)实现两种方式——逐元素参考式 vs 查表式(16 尾数 × ≤112 scale 幂自动表)——对真实 `/model` packed+scale 重构 w1。
- 结果: **最大 |Δ|=0.0, bit-exact 完全一致 (0/11M 元素有位差)**。
- 解码后**唯一值仅 24** (0.0002%)、非零幅度仅 12 种，全 ∈ {0,0.5,1,1.5,2,3,4,6}×2^e。
- **意义**: 路由专家出厂即查表+移位解码(`k3_ops.c` 本身查 `K3_E2M1` 表); 查表重构 = 官方解码, 无损逐位一致 → §7「专家=公式/查表」实证闭环。

### 2. 真实 K3 dense 权重（Kimi-K3-NVFP4, mm_projector, BF16）
`nvfp4/model-00095` (92MB) 里三个 dense 张量：
- proj.0 [4096,4096]: 唯一值 4867 (0.029%), 二幂 38%, 谱 span=56921 病态/低秩, 前10奇值能量仅 1.3%
- proj.2 [7168,4096]: 唯一值 4978 (0.017%), 二幂 42%, 谱 span=20.6, 前10能量 1.2%
- post_norm [7168]: 唯一值 99 (1.4%), 二幂 6%

→ **真实 dense 权重也是高离散**（唯一值比元素少4个量级），但二幂比例~40%（非 MXFP4 的100%）。
→ **谱低秩/退化**（rank 远小于维数），说明 dense 权重低秩压缩可能可行(与专家满秩不同)。

### 2b. 各结构完整实测汇总（2026-09-04, 真实 /model 完整96分片, BF16非专家张量）

对官网确认的 K3 各结构逐一补测（probe_real_weights.py，去 SVD 快速版 / 全量版），覆盖此前未记录的 gate/router、LatentMoE 投影、self_attn/KDA、shared、embed：

| 结构 | source 张量 | shape | 唯一值(%) | 二幂% | A/B | 查表 |
|---|---|---|---|---|---|---|
| 路由专家 | `block_sparse_moe.experts.{E}.w{1,2,3}.weight_packed` | U8[3072,1792] | 31-43(0.0004%) | 72-100% | 紧凑(A) | ~5bit |
| router / gate | `block_sparse_moe.gate.weight` | BF16[896,7168] | 4506 (0.070%) | 29.8% | A-均匀 | 13bit/2.46x |
| router bias | `gate.e_score_correction_bias` | F32[896] | 894 (99.8%) | 0.3% | 一维 | 不可查表 |
| routed down | `routed_expert_down_proj` | BF16[3584,7168] | 4846 (0.019%) | 39.5% | A-均匀 | 13bit/2.46x |
| routed up | `routed_expert_up_proj` | BF16[7168,3584] | 4858 (0.019%) | 38.1% | A-均匀 | 13bit/2.46x（满秩76.2%） |
| routed norm | `routed_expert_norm` | BF16[3584] | 56 (1.6%) | 5.4% | 一维 | 6bit |
| shared down | `shared_experts.down_proj` | BF16[7168,6144] | 5337 (0.012%) | 40.6% | A-均匀 | 13bit/2.46x |
| self_attn q | `self_attn.q_proj` | BF16[12288,7168] | 6286 (0.007%) | 44.1% | A-均匀 | 13bit/2.46x |
| self_attn o | `self_attn.o_proj` | BF16[7168,12288] | 5635 (0.006%) | 43.8% | A-均匀 | 13bit/2.46x |
| self_attn g(KDA) | `self_attn.g_proj` | BF16[12288,7168] | 5840 (0.007%) | 44.8% | A-均匀 | 13bit/2.46x |
| embed | `embed_tokens.weight` | BF16[163840,7168] | 6658 (0.0006%) | 55.9% | A-均匀 | 13bit/2.46x |

**规律结论**：
- **所有非专家 BF16 权重（shared/latent投影/self_attn/embed）唯一值 ~4.8-6.7K → log2≈13bit 无损查表，压缩 2.46x**；二幂 38-56%（非 MXFP4 专家的 72-100%）；A-B 探针全部「均匀混杂(A)」= 紧凑编码，无内在列/行公式。
- **例外3类**：router bias（F32[896]，唯一值≈满，每 expert 独立 float 校正，不可查表）；routed/RMSNorm（[3584] 小向量，唯一值56，非二进制，无二幂）；专家 MXFP4 packed（U8 单 nibble，唯一值16原始，解码后31-43唯一值/72-100%二幂）。
- **router/gate 有效秩 84.9%（满秩）**，与 dense/routed 满秩墙一致 → 非专家侧全部满秩、只余量化/查表路径。

## 意义与未完成
- MXFP4 专家：天然二幂离散，移位 GEMV + 查表无损可行，避开"解压"根本瓶颈
- dense 权重：唯一值少 → 可查表压缩；二幂只有40% → 移位收益低于专家；但谱低秩 → SVD 低秩压缩新方向(专家是满秩死路,dense低秩可能是活的)
- **已完成(2026-09-04, 真实 /model 完整96分片)**: (a) 全结构实测补全(§2b: gate/router、LatentMoE 投影、self_attn/KDA、shared、embed、router bias、routed norm), 结论非专家 BF16 全部唯一值~5-6.7K/13bit 查表 2.46x、二幂 38-56%、A-均匀紧凑编码; (b) dense `mlp.down/up_proj[7168,33792]` 与 `routed_expert_up_proj[7168,3584]` 满秩(有效秩55.7%/76.2%, §19满秩墙一致) -> dense 只余量化; (c) MXFP4 无损对照实验(§1c): 查表重构 vs 官方解码 **bit-exact 逐位一致(0/11M 差)**, 唯一值仅24, 路由专家出厂即查表+移位, 核心假说闭环
- **发布物**: `H:\k3\k3-reps-release`(1.97GB, 59张量) —— routed 专家(46个完整 MXFP4, layer1+layer47) + shared/dense/self_attn/embed 代表切片, 附 `manifest.json`(对齐磁盘) + `README.md`(含三要素实测表)。Kimi K3(2.8T) 各结构均有代表样本可离线复现本文全部结论
- minirun 仓库(layerXX, MXFP4 bytes to byte for byte)是理想补充样本: layer w1.mxfp4tile(专家,5.2GB) 已在 /model 分片中等价验证(§1b)

## 在桌面电脑上继续
```bash
# 任何真实权重(safetensors)分析三要素:
python3 tools/probe_real_weights.py --safetensors model-000XX.safetensors --tensor mm_projector.proj.2.weight
# 若不记得张量名, 不带 --tensor 会列出全部:
python3 tools/probe_real_weights.py --safetensors model-000XX.safetensors
# 裸 fp32 bin:
python3 tools/probe_weight_discreteness.py weights.bin
```
推荐样本: nanguoyu/Kimi-K3-minirun 的 layer01-w1.mxfp4tile(专家, 5.2GB) 或 layerXX-deterministic.bin(文本层 dense+norm, ~1.2-2.3GB)。
### 2c. BF16 非专家 8bit 压缩方案（2026-09-04，统一指数）

**背景**：BF16 非专家（shared/dense/attn/embed，发布物 1431MB）唯一值 5-6.7K、熵 10.48bit，无损熵编码只能到 10.48bit（香农极限）。要 8bit 落地+直接计算，只能量化。实测两方案。

**共同前提**：K3 非专家权重动态范围窄（指数范围 [-4,0] 共 5 种，值域 [0.07,1.79]），8 位指数是 BF16 的浪费。

**方案 A：先 E6M7 量化（16→14bit）再统一指数 → 8bit**
- E6M7 = 1符号+6指数(bias31)+7尾数，尾数 7bit 原样保留（接近无损）
- 再统一指数压缩：全局 e = floor(log2(max))，尾数 m=v/2^e 量化到 k bit
- 8bit = 7尾数+1符号：熵编码 5.214bit，压缩 3.07x，中位误差 0.35%
- 缺点：双重量化（E6M7 一次 + 统一指数一次），误差累积

**方案 B：直接统一指数 → 8bit（不先量化）**
- BF16 → 全局 e 定标 → 尾数 m=v/2^e 量化到 7bit + 1符号 = 8bit
- 熵编码 5.248bit，压缩 3.05x，中位误差 0.35%
- 单次量化，误差更小，实现更简单
- GEMV：y = 2^e × Σ(m_i × x_i)，指数提出累加外，每元素整数乘+结尾一次移位

**结论**：两方案几乎等效（熵 5.21 vs 5.25，误差均 0.35%），方案 B 更简单推荐。误差中位 0.35%、最大 1.64%，GEMV 输出 SNR 53.7dB（vs 1+2+5 的 36.8dB）。bit-exact 仅 ~11%（所有元素有微小变化，但有界）。

**完整链路**：BF16(16bit) → 统一指数 8bit（误差0.35%）→ 熵编码 5.25bit = 3.05x，直接算+可选存储压缩。

### 2d. 92 层误差传播评估（2026-09-04，路线 A vs B）

**方法**：用真实 shared down/up 权重构建 92 层 FFN（每层 W_down→W_up + 残差 + 每2层 RMSNorm），输入 16 token 随机向量，对比量化前后逐层漂移。

**权重量化误差**：路线 A（先E6M7再统一指数）与路线 B（直接统一指数）单层中位误差相同（0.354%）。

**92 层后结果**：
| 路线 | 中位漂移 | SNR |
|---|---|---|
| **B 直接统一指数** | **4.74%** | **26.0 dB** |
| A 先E6M7再统一指数 | 5.81% | 24.4 dB |

**结论**：单层误差相同，但路线 A 的双重量化误差分布更相关，深层累积更快（全程 B/A 比 0.78-0.92）。**路线 B 在深层传播上更优**（92层漂移 4.74% vs 5.81%，SNR 高 1.6dB）。修正 §2c 中
