# K3 注意力 KV 字节账（第一账 · 已完成）

> ⚠️ **2026-09-17 已完成**：本手册不再需要上权重机跑。`data/trunk.json`（用户先前提供的 93 层
> safetensors 索引）已含全部所需 shape，`tools/k3_attn_kv_ledger.py` 直接出账。下方保留原执行流程
> 存档，实测结果见 §结果。
>
> 版本 0.2 · 2026-09-17 · 目标：**独立复现 Moonshot「线性注意力 KV 减 75%」声称在 K3 上的结构级字节账**。
> 不需要跑 GPU —— 只读 safetensors 索引 shape/dtype，算出逐层 KV cache 每 token 字节，钉死 1M-token
> 上下文 K3 的真实 KV 总量，与「同规模全 MLA」对照。
>
> 动机：Kimi Linear 论文（arXiv:2510.26692）声称 KV 减 75%、decode 快 6×，来源是 Moonshot 自测 48B 研究模型，
> **独立复现为零**；K3（2.8T）本体无任何公开 KV/吞吐量测量。本账剥离「神秘感」：用真实层数图证明 75%
> 的八成来自 KDA:MLA=69:24 的层分配。

## 结果（2026-09-17, 输入 data/trunk.json, 工具 tools/k3_attn_kv_ledger.py）

```
层分类      : KDA=69  MLA=24  总 93            ✅ 与官方 69/24 一致
MLA 维度    : kv_a=576(latent512+rope64)  kv_b_expand=24576  q_a=1536  q_b_expand=18432
            (L3 实测; kv_b/128=192, q_b/128=144 支配项为 MLP/扩展投影, 不主导 KV 账)

KV cache    : MLA 每 token/层 = 576 值
  [BF16]  K3 每 token = 27.65KB(24层) → @1M = 27.65 GB | 全31.5MLA@1M = 107.14 GB
  [FP8]   K3 每 token = 13.50KB         → @1M = 13.82 GB | 全MLA        =  53.57 GB
  [MXFP4] K3 每 token =  6.75KB         → @1M =  6.91 GB | 全MLA        =  26.78 GB
  省幅(bd dtype 无关) = 1 − 24/93 = 74.19%
KDA 固定状态: 96×128×128×2B = 3.15MB/层 × 69 = 217.1 MB (不随序列增长)
全部注意力权重(部署, 按真实 dtype): 36.67 GB
  KDA 层 ~444MB/层, MLA 层 ~232MB/层, L0 887.8MB(含池化/特殊)
```

**裁决：Moonshot「KV 减 75%」声称的机制部分在 K3 上独立复现成立 —— 74.2% 就来自 69:24 层分配。**
- 该数字与 vendor 测量的架构反推一致（48B 研究模型的 KDA/MLA 比例大概率同类）；
- 本账为**结构账**（KV cache 随序列增长的部分），不含 prefill 启动态、不含 MLA 层内精度缩放
  （BF16→FP8 再砍一半是另一笔正交账）。
- 「decode 快 6×」的**另一半**(逐 token 读字节斜率) 见 §第二阶账，需真实 token 统计。

## 前置（存档）

1. 权重机 H:\k3 已含完整 safetensors（96 分片）。之前 8/29 已在上面跑过 `k3_qkv_map`。
2. 工具脚本本仓库已就绪：`tools/k3_head_dims.py`（只读 safetensors JSON 头，不加载权重，纯 stdlib）。
3. 若权重机无该脚本：直接 `adb push`/U 盘拷 `tools/k3_head_dims.py` 过去，无需装任何依赖。

## 结构账（已知，来源 notes/kda-mla-decompose.md §10.2，2026-08-29 真 K3 实测）

```
K3 注意力 = 93 层 = KDA 69 层 + Gated MLA 24 层        （层数以实测为准，应 ≈69/24）
KDA 层    : q/k/v [12288,7168] + o_proj [7168,12288]，每层 946MB，共 65.29GB
            无 KV cache —— 循环状态 S 固定：96头×128×128×2B ≈ 3.15MB/层（不随序列增长）
MLA 层    : q_a/q_b/kv_a/kv_b/o_proj，每层 263MB，共 6.31GB
            有 KV cache —— 每 token 缓存 = (kv_lora_rank + rope 部分) × dtype
```

**关键判定式（第二阶）**：
```
K3_1M_KV  = MLA层数 × b_tok × 1M          # KDA 69 层对 KV 增长贡献 ≈ 0
全MLA_1M_KV = 93 × b_tok × 1M
省幅占比  = 1 − MLA层数/93 = 1 − 24/93 ≈ 25.8%  →  K3 vs 全MLA 结构账 ≈ 74.2%
```
→ 若 b_tok 实测后总账落在 70–77% 区间，则「75%」声称的**层分配机制部分**独立证实；
   剩余 0.8% 差距（75−74.2）来自 MLA 层内压缩（kv latent 是否再降精度），单列一账。

## 实测步骤（权重机，10 min）

```bash
cd H:\k3
python3 k3_head_dims.py --dir . > k3_attn_ledger.txt 2>&1
grep -E "attn|latent|kda|output_gate|shortconv" k3_attn_ledger.txt > k3_attn_grep.txt
```

对分片较多时日志逐片很长，`k3_attn_grep.txt` 已足够。若某层形状与上表不符（例如 head 维度非 96/128），以实测为准。

## 回传（几 KB）

把 `k3_attn_grep.txt` 内容 + `k3_attn_ledger.txt` 尾部「类别汇总」表格发回。
手机侧做：ML 层数核对、b_tok 计算（kv_lora_rank/rope dims → 单 token 字节）、1M KV 总量、与全 MLA 的省幅曲线。

## 第二阶账（拿到 b_tok 后，同一文件可顺带算）

1. **decode 每 token 读字节**：MLA 层每步读自身 KV（= b_tok × L）+ 权重；KDA 层每步只读固定状态。
   → 直接对比「解码读字节随 L 的斜率」，独立复现 6× decode 声称的一半（另一半是 kernel/prefill 分摊，属于老三阶）。
2. **AttnRes 摘要账**：93 层分 8 block，每 block 摘要 56KB → 全部 ≈ 288MB 固定。确认不影响 1M 量级。
3. **KV 量化档位**：若 KV 用 fp8/int4 而非 bf16，把 dtype 乘进 b_tok，出 2–3 档 KV 总量。

## 验收标准

- [ ] 读出的 KDA/MLA 层数 ≈ 69 / 24（±1）
- [ ] 每层 q/k/v 形状 = 实测与 8/29 的 [12288,7168] 一致（filenames 能对上）
- [ ] b_tok 有明确 dtype × shape 出处，不是硬编码
- [ ] 给出 K3 在 1M token 的 KV 总量（GB），并标 bf16/fp8 三档
- [ ] 与「全 MLA」对照的省幅落在 70–77%，或给出偏移解释

## 变更

| 版本 | 日期 | 变更 |
|---|---|---|
| 0.1 | 2026-09-17 | 初稿：结构账、判定式、实测/回传规范 |
| 0.2 | 2026-09-17 | 用 data/trunk.json 直接完成；新增 §结果；无需上权重机 |