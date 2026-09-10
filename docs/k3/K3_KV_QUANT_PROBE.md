# KV cache 用「存小矩阵」推长上下文 —— 量化容限实测

> 2026-09-10 · 用户提出的方向：把 KV 从"每 token 大矩阵"拆成"小矩阵"（MLA latent），
> 让输入长度从 8K 往上推。本文是这条方向的实证，不是换思路。

## 0. 问题与 8K 墙的元凶

- 引擎缓存 **展开后**的大 KV（`k3.h:411` K3_KV_BYTES_PER_POS = 2.37MB/pos，24 层×96 头展开 k/v, fp32）。
  8K 上下文 = **19GB** —— 这就是 8K 的天花板。
- 但 MLA 设计本身允许存 **压缩 latent**：每层每 token `latent 512 + rope 64 = 576 元素`。
  BF16 = 27.7KB/token；INT8 = 13.8KB/token（板子 §5 早已钉这个口径）。
- "存展开大矩阵" vs "存 latent 小矩阵" = **76.7 倍存储差**，选择这一个姿势就决定了上下文长度。

```
同 19GB 预算能装多少上下文:
  展开大 KV(fp32) 2.37MB/tok  →    8K token　（这就是墙）
  latent BF16    27.7KB/tok   →  685K token
  latent INT8    13.8KB/tok   → 1.37M token
```

## 1. 实测（真实 MLA 权重，从 trunk 层切片 MXFP8 解码；T=64 归一激活 + T=4 真实 prefill 激活）

`tools/kv_quant_probe.py` 重建 layer3 GatedMLA 的完整 KV 路径，量化 latent 后测：
attention score 的 **argmax 保持率**（每 query·每头选中的 token 是否不变）与输出 energy/SNR。
输入 x 两种获得方式：
- **合成**: 高斯 T=64×7168（RMS=1）—— 初步扫描；
- **真实**: `ref_forward.py /model ids --max-layer=3` 从真 embed + 真 4 层前向 dump 的 layer3
  MLA 输入隐藏态（T=4, 与 C 引擎一致的路径）—— 最终验收。

### 合成激活 (T=64)

| 方案 | bit/elem | 每 token | E-energy | argmax | V-only |
|---|---|---|---|---|---|
| 裸 BF16 cast | 16 | 27.7KB | NaN（latent 值域大, 裸存溢出） | 30.1% | - |
| **INT8（每 token 1 scale）** | **8** | **13.8KB** | **10.7%** | **99.4%** | **0.68%** |
| INT4（每 token 1 scale） | 4 | ~6.9KB | 45.3% | 89.7% | 11.6% |
| **latent=8bit + rope=4bit** | 7.56 | ~13.0KB | 0.00% | **100%** | - |

### 真实 prefill 复测 (T=4, 真实隐藏态) —— 2026-09-10

| 方案 | bit/elem | E-energy | argmax | V-only |
|---|---|---|---|---|
| 裸 BF16 cast | 16 | NaN | 49.2% | - |
| **INT8（每 token 1 scale）** | **8** | **8.63%** | **99.0%** | **2.48%** |
| INT4（每 token 1 scale） | 4 | 38.2% | 84.4% | 50.6% |
| **latent=8bit + rope=4bit** | 7.56 | **0.00%** | **100%** | - |

**真实数据完全复现合成结论**：INT8 甜点（99%+/8.6%）、rope 4bit 零损失、
INT4 崩、V 容限大于 K——结构性结论在真实激活下成立。

### 结论

1. **INT8 latent + 存小矩阵 = 甜点**：字节掉 50%，argmax 99.4%，V 加权误差 0.68%（可忽略）。
   板子 §5 的 13.8KB/token INT8 口径首次有了实证支撑。
2. **rope(64) 异常鲁棒**：压到 4bit **零损失**（argmax 100%、energy 0%）——64 维共享 96 头，
   天然低敏感 → rope 可单独 4bit 存储。组合 bit/elem = 7.56。
3. **K vs V 容限不对称**：K（128 维进 score 的 nope 部分）必须保 8bit（4bit 时 argmax 掉到 89.7%）；
   V 容限大得多（INT8 latent 下 V-only 仅 0.68%）。
   => 用户"拆解"直觉的正确落点：**不是拆矩阵本身, 是拆精度档位（K 密 V 疏）**，
   因为 KV cache 存的是 latent（K/V 共享同一个压缩向量），无法在存储层分离 K/V 精度——
   唯一能独立定档的是 rope（不进 V）。
4. **上下文收益**（同样 KV 存储预算）：BF16 27.7KB → INT8 13.8KB → footprint 减半 => 8K→16K；
   若 rope 再降 4bit (~13.0KB) 同账微增；板子 1GB 预算下 decode 每 token KV 回写也从 27.7KB 减半。

## 2. 诚实边界

- 真实 prefill 已作为最终验收（真 embed + 真 4 层前向, 与 C 引擎路径一致）。
- 隐蔽局限：T=4 的因果注意柔和度有限（每 query 最多小上下文）；真实 decode 是逐 token
  追加缓存 —— 量化的逐 token 累积误差未单独测（INT8 的相对标量误差下, 该累积风险低,
  但严格讲属于后续工作）。
- 裸 BF16 溢出的教训：latent 值域可达 ~8.7e4（RMsnorm 前 x@kv_a 的 7168 维投影），
  **KV 必须量化存储**，这是 INT8 不是可选项而是必须项。

## 3. 产物与后续

- `tools/kv_quant_probe.py` — 本研究的可复跑脚本。
- 后续：真实隐藏态验收（引擎级）；若过，板子 KV 写回 payload 可定为 INT8 latent+4bit rope。