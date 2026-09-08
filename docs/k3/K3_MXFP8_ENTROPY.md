# K3 MXFP8_E8M7_128 熵编码基准 (2026-09-08 rebuild)

## 背景
- `/mnt/nvme` 上的 K3 trunk 原始数据被误删，2026-09-08 用 `pack_trunk.py` 逐字节重建
  `trunk.bin`（108.81GB，93 层，nbytes 校验 MATCH = 0 diff）。
- 随后用 `tools/trunk2mxfp8.py`（per-128 `MXFP8_E8M7_128` 行交错布局
  `[scales: ngrp][codes: cols]`）全量量化 → `trunk_p128t_full/`：
  - `trunk.bin` = 56.60GB（56,604,827,648 B，压缩 1.92x）
  - `trunk.json` = 396KB
  - 量化 1148 个 2D BF16，BF16 保留 801（白名单 gate/mlp_res_proj/self_attention_res_proj + dense L0）
- 本文件记录 rebuild 后的熵编码基准，供后续对比（旧的 `evidence_p128.txt` 只记了
  引擎 logits 对比，无熵基准）。

## 方法
- 工具：`tools/entropy_p128.py`（LAYERS = [1, 11, 12, 31]）
- 对每层每个 `MXFP8_E8M7_128` 张量：
  - 剥掉每行 `ngrp` 个 scales 头，取 codes 流（连续 8-bit codes）
  - `mag.Ent` = 7-bit 幅值熵（sign 剔除）；`byte.Ent` = 8-bit 码字熵（含 sign）
  - 块 Huffman（blk=4096 + 4B/block 偏移表）与 zlib（每块 level 9 + 4B 头）
  - 对比当前存储 = 8 + 8/128 = 8.0625 bit/elem

## 结果
### layer 1
| tensor | elems | mag.Ent | byte.Ent | huff(4096) bit | zlib(4096) bit | h save% | z save% |
|---|---|---|---|---|---|---|---|
| routed_expert_down_proj.weight | 25,690,112 | 5.93 | 6.93 | 6.99 | 7.20 | 13.3 | 10.7 |
| routed_expert_up_proj.weight | 25,690,112 | 6.08 | 7.08 | 7.13 | 7.35 | 11.6 | 8.8 |
| down_proj.weight | 44,040,192 | 6.23 | 7.23 | 7.28 | 7.51 | 9.6 | 6.9 |
| gate_proj.weight | 44,040,192 | 6.20 | 7.20 | 7.25 | 7.47 | 10.0 | 7.4 |
| up_proj.weight | 44,040,192 | 6.19 | 7.19 | 7.24 | 7.46 | 10.2 | 7.5 |
| b_proj.weight | 688,128 | 5.97 | 6.97 | 7.02 | 7.23 | 12.9 | 10.3 |
| f_a_proj.weight | 917,504 | 5.99 | 6.99 | 7.05 | 7.26 | 12.5 | 10.0 |
| f_b_proj.weight | 1,572,864 | 6.11 | 7.11 | 7.16 | 7.38 | 11.2 | 8.5 |
| g_proj.weight | 88,080,384 | 6.08 | 7.08 | 7.13 | 7.34 | 11.6 | 8.9 |
| k_proj.weight | 88,080,384 | 5.97 | 6.97 | 7.02 | 7.23 | 12.9 | 10.3 |
| o_proj.weight | 88,080,384 | 5.94 | 6.94 | 6.99 | 7.21 | 13.3 | 10.6 |
| q_proj.weight | 88,080,384 | 5.97 | 6.97 | 7.02 | 7.23 | 12.9 | 10.3 |
| v_proj.weight | 88,080,384 | 5.96 | 6.96 | 7.01 | 7.22 | 13.0 | 10.5 |

### layer 11
| tensor | elems | mag.Ent | byte.Ent | huff bit | zlib bit | h save% | z save% |
|---|---|---|---|---|---|---|---|
| routed_expert_down_proj.weight | 25,690,112 | 5.94 | 6.94 | 7.00 | 7.21 | 13.2 | 10.6 |
| routed_expert_up_proj.weight | 25,690,112 | 5.94 | 6.94 | 7.00 | 7.21 | 13.2 | 10.6 |
| down_proj.weight | 44,040,192 | 6.10 | 7.10 | 7.15 | 7.37 | 11.3 | 8.6 |
| gate_proj.weight | 44,040,192 | 6.13 | 7.13 | 7.18 | 7.40 | 10.9 | 8.2 |
| up_proj.weight | 44,040,192 | 6.15 | 7.15 | 7.19 | 7.41 | 10.8 | 8.1 |
| g_proj.weight | 88,080,384 | 6.10 | 7.10 | 7.15 | 7.36 | 11.4 | 8.7 |
| kv_a_proj_with_mqa.weight | 4,128,768 | 6.05 | 7.05 | 7.10 | 7.32 | 12.0 | 9.3 |
| kv_b_proj.weight | 12,582,912 | 6.12 | 7.12 | 7.16 | 7.38 | 11.2 | 8.4 |
| o_proj.weight | 88,080,384 | 5.81 | 6.81 | 6.86 | 7.08 | 14.9 | 12.2 |
| q_a_proj.weight | 11,010,048 | 6.17 | 7.17 | 7.23 | 7.44 | 10.3 | 7.7 |
| q_b_proj.weight | 28,311,552 | 6.07 | 7.07 | 7.12 | 7.34 | 11.7 | 9.0 |

### layer 12
| tensor | elems | mag.Ent | byte.Ent | huff bit | zlib bit | h save% | z save% |
|---|---|---|---|---|---|---|---|
| routed_expert_down_proj.weight | 25,690,112 | 5.93 | 6.93 | 6.99 | 7.19 | 13.3 | 10.8 |
| routed_expert_up_proj.weight | 25,690,112 | 5.95 | 6.95 | 7.00 | 7.21 | 13.2 | 10.5 |
| down_proj.weight | 44,040,192 | 5.68 | 6.68 | 6.74 | 7.04 | 16.4 | 12.7 |
| gate_proj.weight | 44,040,192 | 6.10 | 7.10 | 7.15 | 7.37 | 11.3 | 8.6 |
| up_proj.weight | 44,040,192 | 6.10 | 7.10 | 7.15 | 7.36 | 11.3 | 8.7 |
| b_proj.weight | 688,128 | 5.97 | 6.97 | 7.02 | 7.23 | 12.9 | 10.3 |
| f_a_proj.weight | 917,504 | 5.89 | 6.89 | 6.94 | 7.15 | 13.9 | 11.3 |
| f_b_proj.weight | 1,572,864 | 6.11 | 7.11 | 7.16 | 7.38 | 11.1 | 8.4 |
| g_proj.weight | 88,080,384 | 6.08 | 7.08 | 7.12 | 7.34 | 11.6 | 9.0 |
| k_proj.weight | 88,080,384 | 5.96 | 6.96 | 7.00 | 7.22 | 13.1 | 10.5 |
| **o_proj.weight** | 88,080,384 | **4.27** | **5.27** | **5.33** | **5.88** | **33.9** | **27.1** |
| q_proj.weight | 88,080,384 | 5.95 | 6.95 | 7.00 | 7.21 | 13.2 | 10.5 |
| v_proj.weight | 88,080,384 | 5.97 | 6.97 | 7.02 | 7.23 | 13.0 | 10.3 |

### layer 31
| tensor | elems | mag.Ent | byte.Ent | huff bit | zlib bit | h save% | z save% |
|---|---|---|---|---|---|---|---|
| routed_expert_down_proj.weight | 25,690,112 | 5.98 | 6.98 | 7.03 | 7.25 | 12.8 | 10.1 |
| routed_expert_up_proj.weight | 25,690,112 | 6.00 | 7.00 | 7.05 | 7.27 | 12.6 | 9.9 |
| down_proj.weight | 44,040,192 | 6.08 | 7.08 | 7.13 | 7.35 | 11.6 | 8.8 |
| gate_proj.weight | 44,040,192 | 6.09 | 7.09 | 7.14 | 7.36 | 11.5 | 8.7 |
| up_proj.weight | 44,040,192 | 6.09 | 7.09 | 7.14 | 7.36 | 11.5 | 8.7 |
| g_proj.weight | 88,080,384 | 6.10 | 7.10 | 7.15 | 7.36 | 11.3 | 8.7 |
| kv_a_proj_with_mqa.weight | 4,128,768 | 6.05 | 7.05 | 7.10 | 7.32 | 11.9 | 9.2 |
| kv_b_proj.weight | 12,582,912 | 6.15 | 7.15 | 7.19 | 7.41 | 10.8 | 8.1 |
| o_proj.weight | 88,080,384 | 6.03 | 7.03 | 7.08 | 7.29 | 12.2 | 9.5 |
| q_a_proj.weight | 11,010,048 | 6.20 | 7.20 | 7.26 | 7.47 | 10.0 | 7.3 |
| q_b_proj.weight | 28,311,552 | 6.06 | 7.06 | 7.11 | 7.32 | 11.8 | 9.2 |

### aggregate（4 层合计）
| tensor | elems | huff bit/elem | h save% | zlib bit/elem | z save% |
|---|---|---|---|---|---|
| b_proj.weight | 1,376,256 | 7.02 | 12.9 | 7.23 | 10.3 |
| down_proj.weight | 176,160,768 | 7.08 | 12.2 | 7.32 | 9.3 |
| f_a_proj.weight | 1,835,008 | 7.00 | 13.2 | 7.20 | 10.6 |
| f_b_proj.weight | 3,145,728 | 7.16 | 11.2 | 7.38 | 8.4 |
| g_proj.weight | 352,321,536 | 7.14 | 11.5 | 7.35 | 8.8 |
| gate_proj.weight | 176,160,768 | 7.18 | 10.9 | 7.40 | 8.2 |
| k_proj.weight | 176,160,768 | 7.01 | 13.0 | 7.22 | 10.4 |
| kv_a_proj_with_mqa.weight | 8,257,536 | 7.10 | 12.0 | 7.32 | 9.2 |
| kv_b_proj.weight | 25,165,824 | 7.18 | 11.0 | 7.40 | 8.3 |
| o_proj.weight | 352,321,536 | 6.57 | 18.6 | 6.87 | 14.8 |
| q_a_proj.weight | 22,020,096 | 7.24 | 10.2 | 7.46 | 7.5 |
| q_b_proj.weight | 56,623,104 | 7.12 | 11.7 | 7.33 | 9.1 |
| q_proj.weight | 176,160,768 | 7.01 | 13.0 | 7.22 | 10.4 |
| routed_expert_down_proj.weight | 102,760,448 | 7.00 | 13.2 | 7.21 | 10.5 |
| routed_expert_up_proj.weight | 102,760,448 | 7.04 | 12.7 | 7.26 | 10.0 |
| up_proj.weight | 176,160,768 | 7.18 | 10.9 | 7.40 | 8.2 |
| v_proj.weight | 176,160,768 | 7.01 | 13.0 | 7.22 | 10.4 |

## 观察
- 多数张量 byte.Ent 6.9-7.2 bit（信息密度高，接近 8-bit 上界），Huffman 仅能省 ~10-13%。
- 例外：**L12 o_proj** mag.Ent 4.27 / byte.Ent 5.27，Huffman save 33.9%（整层权重分布极不均匀），
  其 aggregate（全 4 层 o_proj）still 6.57 bit/18.6% save，说明只是 L12 特例。
- 参数量大头（g/q/k/o_proj，各 88M elem/层）熵 ~7 bit，压缩空间在 7→8 之间约 13%。
- 当前 per-128 存储 8.0625 bit/elem vs 理论 Huffman ~7.0+，尚有 ~1 bit/elem 冗余可达。

## 相关文件
- 转换器：`tools/trunk2mxfp8.py`（per-128 行交错 `[scales ngrp][codes cols]`）
- 熵工具：`tools/entropy_p128.py`
- decode 验证：`tools/verify_p128.py`
- 旧基准：`/mnt/h/k3/evidence_p128.txt`（2026-09-07，引擎 logits 对比 rel<10% + argmax SAME，
  无熵数据）