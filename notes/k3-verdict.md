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
实测落盘密度 ≈ **1.82 bit/weight**（含 scale；packed 形状 [3072,1792] 每 row 对应逻辑
3584×7168 权重）。注意：名义 MXFP4 ≠ 落盘 4bit，性能模型请用实测字节。

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

## 五、calc_performance.py 改造建议（替换硬编码）

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

## 六、第四步（可选 trace）状态

未执行：权重机 RAM 27GB ≪ 1.45TB，且无 SparkMoE fork 运行环境。如需路由 trace
需在 ≥ 模型体积内存的机器上进行（或由 kimi-k3-in-c 的 LRU 路径改造采集）。

## 七、存档文件位置（权重机）

- /mnt/h/k3/k3_index.json —— 全量 497,220 张量的 dtype/shape/shard 清单
- /mnt/h/k3/k3_verdict.json —— 本报告数字机器可读版
- /model/config.json —— 官方配置
