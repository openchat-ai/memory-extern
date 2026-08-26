# K3 权重实测裁决报告（回传）

> 来源：权重机 k3（WSL2, H:\k3），2026-08-23
> 方法：safetensors 全量 header 扫描（96 分片，497,220 张量）+ config.json 交叉验证
> 对应手册：k3-onboarding.md v0.1 第二步/第三步。原定 `tools/gguf_dump.c` 针对 GGUF，
> 本权重为 safetensors 格式，改用等效 header 解析（k3_index.json 为全量张量清单存档）。

## 一、四个裁决性参数（全部实测确认）

| 参数 | 实测值 | 旧假设 | 结论 |
|---|---|---|---|
| n_layer | **93**（MoE 层为 layers 1..92 共 92 个；layer0 dense） | 93 | ✓ |
| n_expert | **896**（每 MoE 层 experts.0..895） | 896 | ✓ |
| n_expert_used | **16**（config.json: num_experts_per_token） | 16 | ✓ |
| 单 expert 尺寸 | **17.55 MB/层**（量化态落盘字节，92 层严格均匀） | ? | 新数据 |

config.json 关键值：hidden_size=7168, routed_expert_hidden_size=3584,
num_shared_experts=2, moe_layer_freq=1。
expert 张量结构：w1/w2/w3 各配 weight_packed(U8) + weight_scale(U8)，group=16。

## 二、量化类型

config.json: `mxfp4-pack-quantized` (compressed-tensors)。
**实测落盘密度 = 2.00 bit/weight（数据）/ 2.12 bit/weight（含 scale）**，不是 4bit：
名义格式与打包密度是两回事，K3 把 MXFP4 尾数进一步压到 2bit（4 值/字节打包，
scale 64 值共享 1 个 U8，group=64）。逐字节证据（layer1.experts.0）：

| 权重 | packed (U8) | scale (U8) | 逻辑形状（×4 反推） |
|---|---|---|---|
| w1 | [3072, 1792] | [3072, 112] | [3072, 7168] |
| w2 | [3584, 1536] | [3584, 96]  | [3584, 6144] |
| w3 | [3072, 1792] | [3072, 112] | [3072, 7168] |

packed 合计 16.52MB + scale 合计 1.03MB = 17.55MB/单 expert（与运行时 cache 槽位一致）。
注意：名义 MXFP4 ≠ 落盘 4bit，性能模型请用实测字节（25.83GB/token 基于此）。

## 三、模型总量与分片

- 分片数：96（model-00001..00096-of-000096.safetensors）
- 总大小：**1.561 TB**
- 结构校验：抽样 5 分片 header 全部可解析、data_offsets 不越界
- expert 池合计 1.446 TB（占 93%）；其余为 attention/dense/shared/vision/mm_projector

## 四、裁决（推导链代入）

```
单层单 expert（量化态）   = 17.55 MB        （Σ w1+w2+w3 packed+scale，逐字节实测）
每层激活流量              = 16 × 17.55 MB    = 280.8 MB/层
每 token 激活流量         = 92 × 280.8 MB    = 25.83 GB/token   ← 磁盘真实搬运字节
参考：同口径 bf16 等效    = 92 × 16 × 33.06MB = 48.6 GB/token
```

### 裁决表命中第三行："都不是 → 以实测为准"

| 假设 | 判定 |
|---|---|
| 512 GB/token | **否决**（偏差 ~19.8×，任何口径都无法挽回） |
| 52 GB/token | bf16 等效口径下近似成立（48.6 vs 52，差 7%）；但 PIM 分层存储实际搬运的是落盘量化字节，应为 **25.83 GB/token** |

## 五、运行时验证（kimi-k3-in-c 真实推理，2026-08-24）

裁决不是纸面推导——已用 kimi-k3-in-c 引擎在权重机实际跑通，生成输出
`"Hello, I am a 20 year old"`（prompt "Hello"，8 token，gen=8，laptop preset 扩展
--trunk-gb 6 / --cache-gb 4）。运行时统计与裁决数**逐项吻合**：

| 运行时实测（infer3.log） | 数值 | 对应裁决项 |
|---|---|---|
| experts read/token | **25.83 GB**（8 token 全部一致，共 206.64GB） | 每 token 激活流量 25.83 GB ✓ |
| expert cache 槽位 | 227 × **17.56 MB** = 3.99 GB | 单 expert 17.55MB ✓ |
| trunk 全读 | 870.5 GB = 8 × 108.8GB | 每 token 重读 trunk（0/93 pinned） |
| PEAK RSS | 8.76 GB | laptop 预告 8.2GB ✓ |
| 首 token | 1649s（27.5min） | HDD 72MB/s 流式 |
| 双槽流水线 | I/O share 192%（读算重叠，12250s 设备时间被隐藏；bind 0.87s/层） | --trunk-gb 6 生效 |

可复现性：两轮独立运行首 token 均稳定输出 token `11`(`,`)；tokenizer 编码/解码闭环
（"Hello"→19180，全序列精确还原）。

性能上限说明（对 calc_performance.py 口径的实证意义）：HDD 上每 token 纯读
108.8GB trunk + 25.8GB experts ≈ 2 分钟@72MB/s 起步，且 0/93 层可常驻（需 90GB 预算，
机器 28.6GB 不够）——PIM 分层存储模型若假设"trunk 常驻、专家流式"成立，则每 token
仅搬 25.83GB（裁决值）；若假设无常驻，则再叠加 trunk 全读。

## 六、calc_performance.py 改造建议（替换硬编码）

```python
K3 = dict(
    n_layers_total = 93,
    n_moe_layers   = 92,          # layer0 是 dense
    n_expert       = 896,
    n_expert_used  = 16,
    expert_mb_per_layer_quantized = 17.55,   # 落盘字节实测
    activated_gb_per_token        = 25.83,   # = 92*16*17.55MB，分层存储口径
)
assert abs(K3['activated_gb_per_token'] -
           K3['n_moe_layers']*K3['n_expert_used']*K3['expert_mb_per_layer_quantized']/1024) < 0.1
```

⚠️ 另发现公式疑点：现脚本 L163/L173 `k3_layers * k3_activated_gb / bw` 将
activated_gb 再乘层数。若 52 本意是 per-token 总量，则公式存在双重计数；
正确时间模型应为 `t_tok = Σ_层 (n_used × expert_bytes_层) / BW`。
建议改造时一并澄清该口径（本报告 activated_gb_per_token 即 per-token 总量，勿再乘层数）。

## 七、第四步（可选 trace）状态

未执行：权重机 RAM 27GB ≪ 1.45TB，且无 SparkMoE fork 运行环境。如需路由 trace
需在 ≥ 模型体积内存的机器上进行（或由 kimi-k3-in-c 的 LRU 路径改造采集）。

## 八、Trunk MXFP4 量化实测（T5）

trunk（attention/shared/dense/embed/vision）原始 ~110GB → MXFP4 量化后实测 **36 GB**。
量化方式：与专家同款 mxfp4-pack（group=64，scale 共享，2bit 索引编码）。
质量待验：需跑 "Hello" 起手 + 长文续写确认无胡言（shared expert 和 attention 每 token 过）。

每 token 带宽账（最终版）：
- 专家：25.83 GB（top-16 × 92 层 × 17.55MB）
- trunk：36 GB（量化后，全量前向必经）
- 总计：**61.83 GB/token**（全在盘上流时）
- 若 trunk 常驻内存（≥40GB RAM）：每 token 仅流专家 25.83 GB

吞吐模型见 `tools/batch_traffic_model.py`（并集曲线 + trunk 常量可推翻重标）。

## 九、存档文件位置（权重机）

- /mnt/h/k3/k3_index.json —— 全量 497,220 张量的 dtype/shape/shard 清单
- /mnt/h/k3/k3_verdict.json —— 本报告数字机器可读版
- /model/config.json —— 官方配置
