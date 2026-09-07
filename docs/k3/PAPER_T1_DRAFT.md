# Paper (T1) — Working Draft / Materials

> 状态：DRAFT MATERIALS，官方口径已锁定（全部可回溯到 `k3_tech_report.extracted.txt` 行号）。
> `[结果]` 标注处 = 待 PC 侧实验填充；`[待核]` = 报告未披露、需从 checkpoint 确认。
> 官方文档：Kimi Team. *Kimi K3: Open Frontier Intelligence*. Moonshot AI, 2026-07-16. [61]

---

## 0. Working title & one-liner

**Working title:** *Anatomy of a Hybrid Linear-Attention Trunk: An Activation-Level Audit of the KDA Layers in an Open 2.8T-Parameter Model* *(暂定)*

**One-liner:** 对一个已开源的 2.78T 参数生产模型（Kimi K3）做激活级实证解剖，逐条验证其官方声称的机制——3:1 KDA/MLA 混合、通道级遗忘门（α）、NoPE 下的位置委托、AttnRes 深度选择性、KV 缩减与常驻状态。

**定位：** 既不是纯架构发明、也不是纯推理系统；是「官方声明 → 可测机制 → 实测数据」的**可审计案例研究**。卖点 = 超大/开源/文档完备的生产模型 + 公开 47 页官方报告的逐条对账。

---

## 1. 官方口径基线（论文的 §2/§3 素材，全部带引用）

### 1.1 配置总表（表 1，[]内为报告行号）
| 项 | 官方值 | 报告位置 |
|---|---|---|
| 总参数 | 2.78T | L852 |
| 激活参数 | 104.2B | L853 |
| 层数 | 93 = 69 KDA + 24 Gated-MLA + 1 dense | L851/L319/L866 |
| hidden | 7,168 | L854 |
| attention heads | 96 | L860 |
| latent MoE dim | 3,584 (0.5×) | L855 |
| MoE hidden/expert | 3,072 | L856 |
| routed/shared experts | 896 / 2 | L857/L859 |
| active experts/token | 16 (sparsity 56) | L858/L547 |
| context | 1M (训练 8k→64k→1M) | L863/L883 |
| 激活函数 | SiTU-GLU | L865 |
| 量化 | 专家 MXFP4 / 激活 MXFP8 / 非专家高精度 | L913-L918/L1013 |
| ViT | 401M, 27 层, patch 14, 12 heads | L868-L871 |
| MTP | 1 层 (→ EAGLE-3 草稿) | L867/L1019 |

### 1.2 三个核心官方机制声明（论文要逐条审的实验对象）
- **A. 3:1 KDA/MLA 混合 + 末层全全局注意力**（L318-L321）
- **B. KDA 通道级遗忘门 α 承担全部位置/近因, MLA 无 PE（NoPE）**（L481-L485）
- **C. 状态替换 + 常驻隐藏状态:** KDA 以定长状态 S_t 替代增长的 KV 缓存（L325/L1199-1200）; MLA 才存 KV（L479）; FlashKDA 内核 + KDA 前缀缓存（§5, L1206-1207/L1593-1690）
  > ⚠️ **引用诚信修正(2026-09-06):** 先前记录里"KV −75%、1M 解码 6.3×"经查 **不在任何官方源**(技术报告/博客/README)。
  > 报告内唯一量化的相对 K2 效率声明是 **2.5× 缩放效率**(Fig.7/L847)。KV 缩减仅定性描述, 无百分比。论文引用时只能写: "replaces the growing KV cache with a fixed-size recurrent state" (此句可引, 源自报告 §5.1) + 2.5× scaling-efficiency (可引)。切勿引用 -75%/6.3×（无出处）。

### 1.3 KDA 官方方程（论文 §2 核心）
```
S_t = (I − β_t k_t k_tᵀ) Diag(α_t) S_{t−1} + β_t k_t v_tᵀ          (Eq.1, L327-L333)
ṽ_t = S_tᵀ q_t                                                    (L334)
q_t,k_t = L2Norm(Swish(ShortConv(W_qk x_t)))  ∈ R^{d_k}           (Eq.2, L337-L348)
v_t     = Swish(ShortConv(W_v x_t))           ∈ R^{d_v}           (L350-L356)
β_t     = Sigmoid(W_β x_t)                    ∈ (0,1)             (L358-L363)
z_t     = W_α↑ W_α↓ x_t + b_α                ∈ R^{d_k}            (L365-L368)
g_t     = g_min · Sigmoid(e^{A_h} z_t)       ∈ (g_min,0), g_min=−5 (Eq.5, L452-L461)
α_t     = exp(g_t)                            ∈ (e^{−5},1)        (L461)
y_t     = W_o[ Sigmoid(W_g x_t) ⊙ RMSNorm(ṽ_t) ]                  (Eq.6, L474, 全秩门)
```
- chunkwise（chunk size C, 16-token tile; Eq.3-4, L378-L415）: inter-chunk（读 S） + intra-chunk（Tril）
- K3 相对 Kimi Linear 的三处修改（§2.1.1 全文）: 低界衰减（g_min=−5 → 全 tile 可用 Tensor Core）、全秩输出门、通道级 Diag(α)（Eq.1 相对 Kimi Linear 多出 Diag(α_t) 遗忘）

### 1.4 相关的其他官方组件（论文需要给一句话背景）
- **Gated MLA**（DeepSeek-V2, [28]）+ 全秩通道门 `Sigmoid(W_g x) ⊙ ṽ`（L486-L493）
- **Block AttnRes**: 8 blocks × 12 layers + 1 尾块（共 9 块含 embedding）; 块内求和、块间 full attention, O(Ld)→O(Nd)（L539-L540）
- **Stable LatentMoE**: （归一化 latent + SiTU-GLU + Quantile Balancing; L579-L581）
- **EAGLE-3 草稿融合 1st/4th/final AttnRes 块特征**（L1027-L1031）

### 1.4.1 官方评测结果（Ch1 基线，全都来自报告 §6.1/Tables 2-5 及博客/README）

**主结果表（Table 2, L1812-1873）——K3(max) 抽取：**
| 域 | 基准 | K3 | Fable 5 | GPT-5.6 Sol | Claude Opus 4.8 | GPT-5.5 | GLM-5.2 |
|---|---|---|---|---|---|---|---|
| 推理 | GPQA Diamond | 93.5 | 92.6 | 94.1 | 91.0 | 93.5 | 91.2 |
| | CritPt | 23.4 | 28.6 | 32.3 | 20.9 | 27.1 | 20.9 |
| | AA-LCR | 74.7 | 70.0 | 73.7 | 67.7 | 74.3 | 71.3 |
| | HLE-Full (无/有武器) | 43.5/56.0 | 53.3/63.0 | 44.5/58.0 | 49.8/57.9 | 41.4/52.2 | — |
| 编码 | DeepSWE | 67.5 | 70.0 | 73.0 | 59.0 | 67.0 | 46.2 |
| | ProgramBench | 77.8 | 76.8 | 77.6 | 71.9 | 70.8 | 63.7 |
| | Terminal-Bench 2.1 | 88.3 | 88.0 | 88.8 | 84.6 | 83.4 | 82.7 |
| | FrontierSWE | 81.2 | 86.6 | 71.3 | 66.7 | 64.9 | 67.3 |
| | SWE-Marathon | 42.0 | 35.0 | 39.0 | 40.0 | 14.0 | 13.0 |
| | PostTrainBench | 36.6 | 41.4 | 34.6 | 34.1 | 28.4 | 34.3 |
| | SciCode | 58.7 | 60.2 | 56.1 | 53.5 | 56.1 | 50.5 |
| Agent | BrowseComp | 91.2 | 88.0 | 90.4 | 84.3 | 84.4 | — |
| | DeepSearchQA (F1) | 95.0 | 94.2 | — | 93.1 | — | — |
| | GDPval-AA v2 (Elo) | 1686 | 1747 | 1736 | 1593 | 1491 | 1510 |
| | Toolathlon-Verified | 76.5 | 77.9 | 74.9 | 76.2 | 73.5 | 59.9 |
| | MCPMark-Verified | 94.5 | 87.4 | 92.9 | 76.4 | 92.9 | — |
| | AutomationBench | 30.8 | 29.1 | 29.7 | 27.2 | 22.7 | 12.9 |
| | Agents' Last Exam | 28.3 | 25.7† | 29.6 | 27.0 | 26.6 | 20.4 |
| | OSWorld-Verified | 84.8 | 85.0 | 83.0 | 83.4 | 79.0 | — |
| 视觉 | OmniDocBench | 91.1 | 89.8 | 85.8 | 87.9 | 89.4 | — |
| | Math-Vision (无/有Py) | 94.3/97.8 | 94.8/98.6 | 95.8/97.8 | 86.7/97.1 | 92.2/96.8 | — |
| | ZeroBench-main (pass@5) | 23.0/41.0 | 23.0/46.0 | 17.0/35.0 | 17.0/34.0 | 22.0/41.0 | — |

*配置:`max` 推理, temp=1.0; 单步任务 top-p=0.95, agentic top-p=1.0 (L1767-1769)。†Fable 5: 40% 任务降级 (L1811)。*

**图内自研基准 (Table 3, L1932-1967):** KCB2.0 (Claude Code) 73.7 / MIRA 64.1 / KAET 83.5 / CLIF 52.4 / Swarm Bench 76.3 / Online Exp 77.9 / Agent Behavior 65.0 / Faithfulness (1−幻觉率) 85.5。

**第三方 (Table 5, L2110-2116, as of 2026-07-23):** AA Intelligence Index v4.1 #4/580 (=57.1); Vals Index #2/39 (=74.7); WebDev Arena Elo **#1/99** (1678, 首个登顶的开源模型, L2076-2078); Text Arena #8/200 (1486); Agent Arena #4/37 (9.1)。

**成本效率 (Fig.13/L2087-2119)** — 论文可引 "score/cost frontier":
- KCB2.0: K3 落后 Fable 5 4.0 分但 **38% 成本**
- BrowseComp: 91.2% @ **$2.03/任务**, 为 GPT-5.6 Sol 的一半、Claude max-effort 的约 1/10
- GDPval-AA v2: 与 Sol 差距 <50 Elo, 成本低 13%, 比 Fable 5 便宜 2.6×
- AA-Briefcase: 第二, 成本约为 Fable 5 的一半

**官方 API 定价/部署口径 (博客):** $0.30/MTok cache-hit / $3.00 cache-miss / $15.00 output; Mooncake cache-hit >90% (coding workloads); 推荐 ≥64 加速器超节点部署; vLLM 贡献 KDA 前缀缓存。

### 1.4.2 官方"比 K2 更强"的效率声明（唯一可引的量化口径）
- **缩放效率 2.5×** over K2（Fig.7 拟合缩放曲线, L847）——这是官方报告里唯一相对 K2 的定量效率提升，论文引用时用这个，不用任何没有出处的 KV−75%/6.3×。

---

## 2. 论文的叙述骨架（章节 → 官方声明依赖）

| 章 | 内容 | 主要依赖声明 | 素材状态 |
|---|---|---|---|
| Ch1 | K3 能力/配置/基线定位、官方评测/成本效率 | 1.1 + 1.4.1/1.4.2 | 官方已锁 ✓ |
| Ch2 | 官方机制描述 + 我们对每条的可测试化（方程、探针映射） | 1.2/1.3 | 官方已锁 |
| Ch3 | KDA 头维度/状态维度实测 | — | ✅ 权重已解（见 §5.2） |
| Ch4 | 激活级审计：α/β 分布、inter/intra 切分、NoPE 位置测试 | B (+C) | [结果]待采集 |
| Ch5 | AttnRes 深度选择性、draft 特征融合 | AttnRes/EAGLE | [结果]待采集 |
| Ch6 | 讨论 + 局限 | — | 草稿 |

---

## 3. 待验证官方声明清单（每条 = 一句可证伪的主张 + 判定标准）

整理成论文图表的假设表。每条都拆到"观察什么指标、什么数据算支持、什么数据算反驳"。

### H1（混合结构）
> 69 KDA + 24 Gated-MLA + 1 末 dense 层, 末层=全局。
- 验证: 权重清单核对（k3_head_dims.py 直接数层）。
- 支持: 与 L866 逐层一致。  反驳: 不一致 → 报告与权重不符（论文最大料）。

### H2（遗忘门承担位置/近因 + 残留 RoPE 槽 NoPE 验证）
> KDA 的 α 通道门编码位置/近因; MLA(NoPE) 应位置无关。
> ⚠️ 权重实测：MLA 含完整 64 维 RoPE 槽（576=512+64, kv_b 输出 96×192=128 content+64 rope）。
> 宣称 NoPE 却没有把槽抹掉——必须实测判定槽实际发挥什么作用。
- 探针: (a) α 对 token 相对距离的统计（长 story 数据上的 α 分布随距离的形状）;
         (b) 交换输入顺序/插入填充 token 后 MLA 输出扰动 vs KDA 输出扰动;
         (c) **切开 MLA q/k**: content(128)/rope(64) 各自算 attention logit 贡献份额 + 零化 rope 块的输出扰动;
             若 rope 块行为同 content（token 依赖、position 无关）→ NoPE 属实;
             若 rope 块有系统性位置依赖 → NoPE 声称与实现不符。
- 支持: MLA 输出对位置不敏感（扰动小）、KDA 敏感; rope 块扰动≈位置表观不敏感。
- 反驳: MLA 输出表现出显著位置依赖 → NoPE 声称打脸（大料）。

### H3（定长状态 / KV 只在 MLA 增长）
> 只有 MLA 存 KV; KDA 是定长状态 S_t; 1M 上下文 KV 只线性涨在 24 层 MLA 上。
> ⚠️ 官方无 "KV −75%" 数字; 可引句子 = "replaces the growing KV cache with a fixed-size recurrent state" (L1199-1200)。
- 探针: 跑 1k/10k/100k token, 测量实际缓存轨迹（KDA 状态定长 vs MLA 缓存增长）。
- 支持: 缓存增长与 24 层 MLA 理论值吻合。
- 反驳: 状态不定长/KDA 层仍有长轨迹 → 官方机制与实际实现不符。

### H4（低界衰减 g_min=−5）
> α 有下界 e^{−5}, 累计衰减有界 → 无溢出风险, 全 tile 可 Tensor-Core。
- 探针: 实测 α_t 最小值是否 ≈e^{−5}（下界饱和观测）、角落极端 case。
- 支持: 观察到贴近 e^{−5} 的下界密度。
- 反驳: α 远低于 e^{−5} 或数值异常 → 低界说在实现中被绕过。

### H5（inter-chunk 承担长程）
> 长程信号走 chunkwise 的 inter-chunk（S_t 路径）, intra-chunk 只管块内。
- 探针: 隔断 S_t（S=0 或剪断跨 chunk 状态）→ 看远端依赖的性能损失; 分层/按距离分解。
- 支持: 切断状态后长程贡献掉。
- 反驳: 长程主要仍在 intra-chunk/MLA 里 → 论文发现与声称不同（可发）。

### H6（AttnRes 深度选择性）
> 每层用伪查询 w_l 从 embedding+前层选择性取信息, 并非均匀残差。
- 探针: 读出每层 α_{i→l} 权重矩阵（8 块级）, 看是否稀疏/集中在特定块。
- 支持: α 集中在少数块/稀疏。  反驳: 近似均匀 → 残差+注意力没啥区别。

### H7（量化口径）
> 专家 MXFP4 / 激活 MXFP8 / 非专家高精度。
- 探针: 权重 dtype 清单（k3_head_dims.py）; 与我们自己的 trunk 8bit 压缩对照。
- 支持/反驳: dtype 分布与 L1013-L1018 文案一致与否。注意: 我们自己压的更激进, 论文要定性为"我们额外做的部署实验", 不与官方混谈。

### H8（draft 融合 1st/4th/final AttnRes）
> EAGLE-3 草稿输入的三个特征来自 1st、4th、final AttnRes 块。
- 探针: 检查权重中存在仅在 1st/4th/final 采样输出的融合投影（W_E3 等）。
- 支持: 结构核对直接发现。  反驳: 结构不符。

---

## 4. 实验复杂度/资源预估（论文需要摊的账）

- 权重侧: 只需 head-dims（k3_head_dims.py）+ dtype 分类 → 一台机器, 秒级。
- 激活侧 (H2/H4/H5): 需要 hook 前向, 采样 "story 长文本" 激活 → 需能跑通前向的机器。
  - 用户当前机器 130s/token（存储压力）: 采 1k token ≈ 1.5 天, 不可行。
  - 修活性常驻后 ~3s/token: 1k token ≈ 50 分钟, 10k ≈ 8 小时。→ **说明 PC 侧修活性是低成本解锁全部实验的关键**。
- MLA/KV 侧 (H3/H8): 需要较长上下文跑 94 层, 成本更高。
- 另一维度: 67 层 KDA 全剖则 93 层 × 常数; 可先取代表层（首个 KDA、中间 KDA、首/末 MLA）。

---

## 5. 风险与开放项

- ✅ **head 维度已解（权重实测）**：KDA k/v/o 输出 = 12,288 = 96×128，state S_t=128×128/head。
- ✅ **MLA 维度解码（权重实测, layer 11）**: DeepSeek-V3 式 MLA 结构——
  `q_a [1536] → q_b [18432]=96×(128 content+64 rope)`; `kv_a [576]=512+64` + `kv_a_layernorm [512]`
  (只归 content); `kv_b [24576]=96×(k128+v128)`; `o_proj [12288]=96×128` (rope 不进输出);
  全秩门 `g_proj [12288,7168]`。
  ⇒ **几何 self-consistent**：KDA 头 128 纯粹；MLA 头 = content(128)+rope(64), K/V 各 128。
- ⚠️ **新可测点 (NoPE vs 残留 RoPE 槽)**: MLA 权重含完整 64 维 RoPE 槽(576=512+64)，但官方声称 NoPE。
  → 把 q/k 切成 content/rope 两块，测量各自对 attention 的贡献：rope 块退化 content(位置无关)
  则 NoPE 属实；有系统位置依赖则与声称冲突。**已并入 H2 探针设计。**
- **[待核] 55G/100G "trunk" 成分**: 已从权重清单解决（trunk.bin BF16 108.8GB：attn 52.8 + shared 24.3 + latent 16.8 + W↓↑ 9.5 + mqa 2.7 + mlp 1.5 + gate 1.2）。896 专家 FFN 不在 trunk。
- **[待核] 版本匹配**: 我们是 55G 8bit 版本回测, 官方是 BF16 trunk; 激活统计若在压缩版跑, 需声明。
- 未有官方基准复现的内部数字 → 全部以可引用公开事实 + 我们自己的观测口径写。

---

## 6. 引用（论文可用, 全部核对自报告 bibliography）

- [61] Kimi Team. *Kimi K3: Open Frontier Intelligence*. Moonshot AI, 2026-07-16. https://www.kimi.com/blog/kimi-k3
- [64] Kimi Team et al. *Kimi Linear: An Expressive, Efficient Attention Architecture*. 2025. arXiv:2510.26692
- [58] Kimi Team. *Attention Residuals*. Preprint, 2026.
- [59] Kimi Team. *Kimi K2: Open Agentic Intelligence*. 2025. arXiv:2507.20534
- [60] Kimi Team. *Kimi K2.5: Visual Agentic Intelligence*. 2026. arXiv:2602.02276
- [28] DeepSeek-AI. *DeepSeek-V2* (MLA). 2024. arXiv:2405.04434
- [72] Yuhui Li et al. *EAGLE-3*. 2025. arXiv:2503.01840
- [105] Alexander Samarin et al. *LK Losses: Direct Acceptance Rate Optimization for Speculative Decoding*. 2026. arXiv:2602.23881
- [14] Yutian Chen et al. *FlashKDA*. MoonshotAI, 2026. https://github.com/MoonshotAI/FlashKDA
- [104] Bita Darvish Rouhani et al. *Microscaling Data Formats*. 2023. arXiv:2310.10537
- [106] Imanol Schlag et al. *Linear Transformers Are Secretly Fast Weight Programmers* (delta-rule). 2021. ICML
- [24] Tri Dao & Albert Gu. *Transformers are SSMs* (Mamba-2/GDN). 2024. arXiv:2405.21060
- [100] Zihan Qiu et al. *Gated Attention* (full-rank output gate context). 2025. arXiv:2505.06708
- [32] Venmugil Elango et al. *LatentMoE*. 2026. arXiv:2601.18089
- [27] Soham De et al. *Griffin* (lower-bounded gate prior). 2024. arXiv:2402.19427
- [98] Zhen Qin et al. *HGRN2* (lower-bounded gate prior). 2024. arXiv:2404.07904
- [93] Bowen Peng et al. *YaRN* (position-extension context / NoPE contrast). 2023. arXiv:2309.00071
- [56] Katharopoulos et al. *Transformers are RNNs*. 2020. ICML

**官方代码/仓库（可引）:**
- Kimi-K3 GitHub README（Model Summary / Eval / Deployment）: https://github.com/MoonshotAI/Kimi-K3
- FlashKDA 内核仓库: https://github.com/MoonshotAI/FlashKDA
- MiniTriton（报告 §7 编译器案例）: https://github.com/MoonshotAI/minitriton（footnote 5, L2257）
- nano-kpu（报告 §7 芯片设计案例, 4mm²/100MHz/8700 tok/s decode）: https://github.com/MoonshotAI/nano-kpu（footnote 6, L2258）
- meta: 权重 HuggingFace moonshotai / ModelScope, License: Kimi K3 License（README §7）

---

## 7. 下一步实现路径（含状态）

- [x] 官方口径锁定: 技术报告 47 页 + 博客 + README 三源比对, 修正 "KV−75%/6.3×" 无出处问题（2.5× 才可引）
- [x] Ch1 官方评测/成本效率基线已填（Table 2/3/5 + Fig.13）
- [x] k3_head_dims.py → PC 已跑 → 头维度已解（d_k=d_v=128, state 128×128; MLA 头 192/256）→ 已填 Ch3 ✓
- [ ] PC 修活性 → 激活侧探针（H2/H4/H5）数据采集脚本
- [ ] 是否保留 "我们 55G trunk 压缩" 作为 Ch7（部署实验）独立小节 —— 悬置，待 PC 结果定