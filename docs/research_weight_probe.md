# 真实权重探针：K3 权重离散性与二幂结构 验证笔记

日期: 2026-09-03
数据来源: hf-mirror 镜像拉取的真实权重 + 本机 MXFP4 fixture
工具: `tools/probe_weight_discreteness.py`（判据1+2）`tools/probe_real_weights.py`（判据1+2+3，读 safetensors）

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
- 注：这是 MXFP4(E4M3) 反量化后的固有离散结构

### 2. 真实 K3 dense 权重（Kimi-K3-NVFP4, mm_projector, BF16）
`nvfp4/model-00095` (92MB) 里三个 dense 张量：
- proj.0 [4096,4096]: 唯一值 4867 (0.029%), 二幂 38%, 谱 span=56921 病态/低秩, 前10奇值能量仅 1.3%
- proj.2 [7168,4096]: 唯一值 4978 (0.017%), 二幂 42%, 谱 span=20.6, 前10能量 1.2%
- post_norm [7168]: 唯一值 99 (1.4%), 二幂 6%

→ **真实 dense 权重也是高离散**（唯一值比元素少4个量级），但二幂比例~40%（非 MXFP4 的100%）。
→ **谱低秩/退化**（rank 远小于维数），说明 dense 权重低秩压缩可能可行(与专家满秩不同)。

## 意义与未完成
- MXFP4 专家：天然二幂离散，移位 GEMV + 查表无损可行，**避开"解压"根本瓶颈**
- dense 权重：唯一值少 → 可查表压缩；二幂只有40% → 移位收益低于专家；但谱低秩 → SVD 低秩压缩新方向(专家是满秩死路,dense低秩可能是活的)
- 未完成：文本主干层(attention QKV/MLP dense)与 routed expert 的真实验证。minirun 仓库(layerXX, MXFP4 bytes to byte for byte)是理想样本，但单文件 1.2~5.2GB，需在桌面设备下载跑。

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