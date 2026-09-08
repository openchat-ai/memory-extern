# K3 head_saliency 全 93 层显著性数据（最终版, gate 哨兵行已剔除）

日期: 2026-09-08
数据源: `/mnt/nvme/trunk/trunk.bin` (BF16 108.8GB) + `trunk.json`
工具: `tools/head_saliency.py`（v2, 含 gate 哨兵行剔除 `gate_row_norms_clean`）
方法: 逐层读权重 → W_o 96 头范数 / gate 896 专家行范数, 计算 cv（变异系数）
覆盖: 0-92 全 93 层, 无缺口。results 文件按时间新→旧合并（新批覆盖旧批污染层）。

## 结果总表

| 分组 | 层数 | gate_cv | W_o_cv | 备注 |
|---|---|---|---|---|
| KDA (v1) | 68 | **0.1502**（全层一致） | **0.0032** | 无哨兵行 |
| Gated-MLA (v2) | 24 | **0.1052**（全层一致） | **0.0027** | 每层 45 哨兵行(专家0-44)已剔除 |
| dense (L0) | 1 | - | 0.0978 | 无 MoE gate |

- 组内 gate_cv **完全一致**到小数点后 4 位（min==max）, 表明结构周期严格: 68 KDA 周期 + 24 MLA 周期。
- MLA 每层 45 个哨兵行、621 个 exp==0xFF, 剔除后真实 cv=0.1052（详见 K3_HEAD_SALIENCY_GATE_SENTINEL.md）。

## 对"剪枝/加速"的结论

### A. 剪头（head pruning）→ 否定
KDA `‖W_o‖` cv=0.0032、MLA cv=0.0027: 96 头范数**几乎完全均匀**（max/min ratio≈1.01）。
剪掉任何头都会破坏结构、且无范数依据。**没有可剪的"死头/弱头"。**

### B. 剪专家（expert pruning）→ 两组皆否定（在原数据口径下）
- KDA gate 行范数 cv=0.15: 896 专家范数较均匀, 无一专家参数显著偏小。
- MLA 剔除哨兵行后 cv=0.105, 比 KDA 更均匀。
- **哨兵行剔除修正了此前"MLA 4.39 ≠ KDA 0.15"的假爆点结论**——两组真实的专家范数分布同量级、都相当均匀。
- 真正可动的方向是 **专家装载/缓存淘汰（动态热度, 笔记 l2-cache-records / predictive-eviction）**, 而非按权重静态剪枝。

### C. Early-exit（跳层）→ 弱否定
92 层 log-importance 斜率 ≈ 5e-06（接近 0）, 尾段无衰减 → 逐层 W_o 总范数不随深度单调下降, 没有"浅层已够"迹象。

### D. 交叉洞察（装载线 ↔ 显著性线）
单调超集（8 遍专家集递增）+ KDA/MLA 范数均匀 → 每层 896 专家无静态热点, 但**动态激活有热点**（高频专家）。这对"LPDDR 按热度驻留"是利好: 驻留名单选热度（动态）, 不靠范数（静态）。均匀范数同时意味着专家间权重大小均衡 → 装载字节分布平坦, 缓存淘汰收益全部来自命中/复用的时序结构（÷5.6 成立）。

## 数据文件

| 文件 | 覆盖层 | 说明 |
|---|---|---|
| `results/head_saliency_20260908_092644.json` | 36-92 | 最新批(修复版), KDA+MLA |
| `results/head_saliency_20260908_091439.json` | 24 MLA | MLA 修复版重跑 |
| `results/head_saliency_20260908_083111.json` | 10-35 | KDA 干净(MLA 已弃用,被 091439 覆盖) |
| `results/head_saliency_20260908_082307.json` | 0-9 | KDA 干净(同上) |

合并脚本: `C:\Users\ADMINI~1\AppData\Local\Temp\opencode\merge_saliency.py`（mtime 新→旧覆盖）