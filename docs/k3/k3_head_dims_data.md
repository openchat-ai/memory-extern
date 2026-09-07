# k3_head_dims.py 运行原始数据

> 工具: `tools/k3_head_dims.py`（`--dir /mnt/nvme/embed/` + 直读 `trunk/trunk.json`）
> 模型: K3 93 层 hybrid MoE, hidden d=7168, align=4096
> 说明: 权重实体在 `trunk.bin`(BF16 108.8GB) / `trunk_mxfp8.bin`(55.6GB), 由 `trunk.json` 索引;
>       embed 层是独立 safetensors 分片。以下为原始读取输出。

## 1. embed 分片 (model-00094-of-000096.safetensors, 4.4GB, BF16)

```
===== model-00094-of-000096.safetensors (4.4GB) =====

===== attention 相关张量(全形状, 判断真实 head 维度用) =====
  weight    BF16  1x7168  0.0M 14.0KB  [attn_qkv]
  weight    BF16  7168    0.0M 14.0KB  [attn_qkv]

===== 参数/字节 类别汇总 (对账 trunk 来源) =====
  attn_qkv     参数=0.000B  字节=  28.0KB
  embed/output 参数=2.349B  字节=   4.4GB
  norms        参数=0.000B  字节=  14.0KB
  TOTAL        参数=2.349B  字节=   4.4GB

统计: 5 个张量, 1 个分片
```

## 2. 层分布

```
n_layers = 93
v1(delta-swish/KDA) 69 层 = [0,1,2,4,5,6,8,9,10,12,13,14,16,17,18,20,21,22,24,25,26,28,29,30,
    32,33,34,36,37,38,40,41,42,44,45,46,48,49,50,52,53,54,56,57,58,60,61,62,64,65,66,68,69,70,
    72,73,74,76,77,78,80,81,82,84,85,86,88,89,90]
v2(Gated-MLA) 24 层 = [3,7,11,15,19,23,27,31,35,39,43,47,51,55,59,63,67,71,75,79,83,87,91,92]
```

## 3. layer 0 (v1/KDA) 张量清单

```
  language_model.model.layers.0.input_layernorm.weight          [7168] BF16
  language_model.model.layers.0.mlp.down_proj.weight            [7168, 33792] BF16
  language_model.model.layers.0.mlp.gate_proj.weight            [33792, 7168] BF16
  language_model.model.layers.0.mlp.up_proj.weight              [33792, 7168] BF16
  language_model.model.layers.0.mlp_res_norm.weight             [7168] BF16
  language_model.model.layers.0.mlp_res_proj.weight             [1, 7168] BF16
  language_model.model.layers.0.post_attention_layernorm.weight [7168] BF16
  language_model.model.layers.0.self_attention_res_norm.weight  [7168] BF16
  language_model.model.layers.0.self_attention_res_proj.weight  [1, 7168] BF16
  language_model.model.layers.0.self_attn.A_log                 [128] F32
  language_model.model.layers.0.self_attn.b_proj.weight         [96, 7168] BF16
  language_model.model.layers.0.self_attn.dt_bias               [12288] F32
  language_model.model.layers.0.self_attn.f_a_proj.weight       [128, 7168] BF16
  language_model.model.layers.0.self_attn.f_b_proj.weight       [12288, 128] BF16
  language_model.model.layers.0.self_attn.g_proj.weight         [12288, 7168] BF16
  language_model.model.layers.0.self_attn.k_conv1d.weight       [12288, 1, 4] F32
  language_model.model.layers.0.self_attn.k_proj.weight         [12288, 7168] BF16
  language_model.model.layers.0.self_attn.o_norm.weight         [128] F32
  language_model.model.layers.0.self_attn.o_proj.weight         [7168, 12288] BF16
  language_model.model.layers.0.self_attn.q_conv1d.weight       [12288, 1, 4] F32
  language_model.model.layers.0.self_attn.q_proj.weight         [12288, 7168] BF16
  language_model.model.layers.0.self_attn.v_conv1d.weight       [12288, 1, 4] F32
  language_model.model.layers.0.self_attn.v_proj.weight         [12288, 7168] BF16
```

## 4. layer 11 (v2/Gated-MLA) 张量清单

```
  language_model.model.layers.11.block_sparse_moe.gate.e_score_correction_bias [896] F32
  language_model.model.layers.11.block_sparse_moe.gate.weight    [896, 7168] BF16
  language_model.model.layers.11.block_sparse_moe.routed_expert_down_proj.weight [3584, 7168] BF16
  language_model.model.layers.11.block_sparse_moe.routed_expert_norm.weight [3584] BF16
  language_model.model.layers.11.block_sparse_moe.routed_expert_up_proj.weight [7168, 3584] BF16
  language_model.model.layers.11.block_sparse_moe.shared_experts.down_proj.weight [7168, 6144] BF16
  language_model.model.layers.11.block_sparse_moe.shared_experts.gate_proj.weight [6144, 7168] BF16
  language_model.model.layers.11.block_sparse_moe.shared_experts.up_proj.weight [6144, 7168] BF16
  language_model.model.layers.11.input_layernorm.weight          [7168] BF16
  language_model.model.layers.11.mlp_res_norm.weight             [7168] BF16
  language_model.model.layers.11.mlp_res_proj.weight             [1, 7168] BF16
  language_model.model.layers.11.post_attention_layernorm.weight [7168] BF16
  language_model.model.layers.11.self_attention_res_norm.weight  [7168] BF16
  language_model.model.layers.11.self_attention_res_proj.weight  [1, 7168] BF16
  language_model.model.layers.11.self_attn.g_proj.weight         [12288, 7168] BF16
  language_model.model.layers.11.self_attn.kv_a_layernorm.weight [512] BF16
  language_model.model.layers.11.self_attn.kv_a_proj_with_mqa.weight [576, 7168] BF16
  language_model.model.layers.11.self_attn.kv_b_proj.weight      [24576, 512] BF16
  language_model.model.layers.11.self_attn.o_proj.weight         [7168, 12288] BF16
  language_model.model.layers.11.self_attn.q_a_layernorm.weight  [1536] BF16
  language_model.model.layers.11.self_attn.q_a_proj.weight       [1536, 7168] BF16
  language_model.model.layers.11.self_attn.q_b_proj.weight       [18432, 1536] BF16
```

## 5. 全模型字节构成 (BF16 trunk, 93 层, 不含 embed)

```
  attn_latent  16821.6 MB
  attn_mqa      2689.7 MB
  attn_qkv     52848.2 MB
  mlp_dense     1453.3 MB
  moe_gate      1181.7 MB
  moe_routed    9454.6 MB
  moe_shared   24310.2 MB
  norm             5.3 MB
  TOTAL      108764.7 MB = 108.765 GB
```

trunk.bin 实测 108,811,952,128 字节 = 108.78 GB，与索引汇总一致。