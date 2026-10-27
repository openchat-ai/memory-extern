# 赫布项目现状（2026-10-24 定稿）

一页看懂：**我们在做什么、做到哪、什么能用、什么别试、怎么跑。**
详细实验记录在 `docs/HEB_EXPERIMENT.md`（§1~§10.24），本文只给结论。

---

## 0. 一句话

**零训练**（不跑任何梯度）把事实注入 0.6B 的 Q4T 量化模型，交付可独立运行的 GGUF；
另有一条**运行时记忆层**（事实不进模型，运行时检索注入），支持多事实。

---

## 1. 三条通路（别混）

| 通路 | 改什么 | 产物 | 状态 | 证据 |
|---|---|---|---|---|
| **赫布写入**（hebb）| FFN 权重：`ΔB = c·v⊗φ/\|φ\|²` | GGUF | ✅ 可交付，**只适合单/少数事实** | §10.9–10.17 |
| **运行时记忆层**（hebb_memory）| 不改模型，运行时把事实拼进提示 | 事实库 JSONL | ✅ 可用，**多事实** | §10.13/10.19/10.23 |
| **方向读出**（hebb_rerank/style）| V 通道方向（语气/形态）| 一个向量 | ⚠ **仅 logit 级**，不能烘进模型 | §10.20–10.24 |

**知识**（答什么）只能走前两条；**行为**（怎么答）只能走第三条。两者不互相替代。

---

## 2. 能交付的东西

### 2.1 GGUF（离线烘入事实）

目录 `/data/data/com.termux/files/home/models/qxt/`

| 文件 | 事实 | 改动量 | 验收（20 条 holdout + 贪心，§10.26）|
|---|---|---|---|
| **`rStar-Coder-hebbit-multi5.gguf`** | **5 条不同模板事实** | ~132KB | **5/5 rank 0、含值 5/5、串扰 0、holdout 污染 7/20** |
| `rStar-Coder-hebbit-multi8.gguf` | 8 条 | ~132KB | 7/8 rank 0、含值 8/8、串扰 0、污染 10/20 |
| `rStar-Coder-hebbit-1L18.gguf` | 2 条 | 131,731 B（**0.056%**）| 2/2 rank 0、串扰 0、**污染 6/20** |
| `rStar-Coder-hebbit-18-22.gguf` | 同上，4 层 | 70,464 B | 2/2 rank 0、污染 4/20 |
| `rStar-Coder-hebbit-3k-Oly1900.gguf` | 同模板多 key（演示）| 144,726 B | ⚠ **审计只存住 1 条**（见 §4）|

> ✅ **106 条 holdout + 配对 McNemar（§10.27）**：
> | 比较 | p | 判定 |
> |---|---|---|
> | 1L18(2条) vs multi5(5条) | 0.607 | **不显著 → multi5 是免费升级** |
> | multi5(5条) vs multi8(8条) | **0.0225** | **显著 → 8 条边际变脏** |
>
> 逐字不同率：1L18 25/106、multi5 28/106、multi8 37/106。
> 语义判据（ast.parse）基座基率只有 17%，**欠功率，只作辅助**。

基座：`rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf`

> ⚠ **旧文档写的"holdout 0/6 逐字一致"作废**（§10.26.5）：6 条样本 + 采样口径
> 漏判，采样噪声底本身就有 1/20。诚实口径 = **20 条 + 贪心解码**。
> 旧 §10.9 的"干净窗口"定义也要按新口径重算。

**白化变体已作废**（§10.30）：旧白化 6/106 的低损伤是**归一化 bug 的假象**
（`r=(φWtφ)/(φWt²φ)`，blue 被衰减 10×、Africa 被放大 55×）。改用 `--norm-key`
修正分母后召回 2/2、损伤 29/106，**与 norm 无差异**（p=0.13）。白化无优势，勿再用。

**记忆层（可交付的窄功能）**：`tools/hebb_memory.py` + `tools/mem_scale.py`。
N=1000（159 真实 + 841 干扰）下：精确 key / 自然问句 / 前置语序 / 带标点 **全部 100%**；
只给实体正确标记歧义；端到端生成 **20/20**。依赖 `soft=True`（数字守卫防伪造年份）；同 key 冲突按 `latest/uses` 消解（§10.33）。
命令行: `python tools/ask.py "Who won the 1954 World Cup?"`。
换词改写不支持（无 embedding 检索，§10.32）。

**multi5 的 5 条事实**（Jupiter / Africa / Everest / Tokyo / blue，
模板各不相同）：关键是 `--orth`——多事实场景不需要改写泛化，
所以把各条 φ 的共性分量正交掉（§10.26.4）。

验收（只读，不修改）：

```bash
python tools/hebb_verify.py /data/data/com.termux/files/home/models/qxt/rStar-Coder-hebbit-multi5.gguf
python tools/hebb_multifact.py --verify <file.gguf> --facts "k1=v1|k2=v2"
```

重建：

```bash
python tools/hebb_deliver.py --layers 18 --c 60 --out /path/out.gguf
```

### 2.2 运行时记忆层（多事实）

```python
from hebb_memory import HebbMemory
m = HebbMemory().add("The country where the 1974 FIFA World Cup was held is", "Germany")
m.answer("What is the capital city of that country?",
         context="The country where the 1974 FIFA World Cup was held is")
# -> ' Berlin...'
```

机制：检索（token+bigram IDF，未见 bigram 硬拒绝）→ **分解式**：记忆只给第一跳
（年份→国家），第二跳（国家→首都）交还模型 → 双模板 + 反向校验仲裁。

实测：

| 测试 | 结果 |
|---|---|
| FIFA 10 条桥接 | **10/10**（旧联合式 8/10）|
| 留出集（夏季奥运会 10 国）| **10/10** |
| 属性扩展 10 国 × 4 属性 | capital 10/10、currency 8/10、language 9/10、continent 8/10 |
| 无关问句 / 库外年份 | 不注入 ✓ |
| 直接召回 | 3/3 |

**天花板**：第二跳 = 模型自身知识。currency 的失分（Italy→lira、Germany→mark）
是**过期知识**，写入类方法都修不了。

### 2.3 K/V 事实块（KV 前缀）

`tools/hebb_kvblock.py` — 事实做成 KV 前缀烘进上下文，3.9 MB / 18 槽。
实测：`off=0` 与"先跑事实再跑问题"**逐字相同**；同块换问句可二次推理（→ Europe）；
问人口会编造。**块后移 8 位会退化**（多出的占位 token 进入 softmax 分母）——
前缀必须纯净（§10.18.2 Knowledge Packs 的定理前提）。

### 2.4 方向读出（仅 logit 级）

```bash
python tools/hebb_rerank.py --cls --rank     # 情感方向
python tools/hebb_style.py --cls --rank      # 代码 vs 散文方向
```

- 句级分类 AUC **1.000**（情感，n=24；代码/散文 n=10，10 次随机方向 mean 0.531、max 0.940）
- 候选重排 6/6（随机期望 1.5）
- 混合情感 9/10、否定 5/5、**强度不可用**（方向是极性轴不是强度轴）
- **不能烘进 GGUF**：V 常数偏移等价于注意力输出偏置，而 Q4T 格式
  **196 个张量、0 个 bias**（§10.25）

---

## 3. 明确做不到 / 死路（勿重试）

| 死路 | 证据 | 章节 |
|---|---|---|
| **同模板多事实**（只差一个 token）| cos 0.98，正交掉共性=删掉事实本身 | §10.11.6 |
| 用 6 条 holdout 判"干净" | 采样噪声底 1/20，贪心 20 条下 1L18 是 6/20 | §10.26.5 |
| 闭式写入**多条**事实（一条 ΔB 装 N 条）| 问句-事实 cos=0.098；同模板仿写簇跨组 cos 0.804 vs 组内 0.852（差 0.048）→ **写不进去**；3k 交付审计 k=1 | §10.15/10.17 |
| 用 `1/\|φ\|²` 之外的核（白化 Σ̂⁻¹）| 不解决路由，只提容量 | §10.15 |
| 置信度边际当接受/回滚信号 | 与正确性**反相关**（正确 London −0.17，错误复读 +0.18）| §10.19.1 |
| V 通道**烘进模型** | Q4T 无 bias 张量 | §10.25 |
| V 通道**行为级**可控（0.6B）| α≥6 输出崩坏，生成层无可测效应 | §10.20.8 |
| "打乱标签"当对照 | 均值差与配对无关，**数学上恒等**，不可能失败 | §10.20.7 |
| 自由生成极性当判据 | 12 样本 9 个是 0（续写里没有情感词）| §10.21.1 |
| 整段子串匹配当答案判据 | Italy 先说 lira、后文才出现 Euro → 假阳性 10/10 | §10.23.4 |

**为什么闭式写入装不下多条**：Hazy 等（arXiv 2607.10034）的定理要求查询是
key 的加噪版本 `k+ε`（`‖ε‖ < √(d/(F log F))`）；我们的问句与事实 cos=0.098
（≈84°），不是噪声而是另一个特征。**这不是实现 bug，是定理前提不成立。**

---

## 4. 已知不足（写明而不是藏起来）

- `3k-Oly1900.gguf` 只存住 1 条事实（Paris）——多 key 在同一 ΔB 里会互相干扰
- 属性模板只覆盖陈述式属性；疑问句（"What is the capital of X?"）在这个
  completion 型基座上会续写成新问句，必须用陈述式模板
- 属性模板是为 **capital/currency/language/continent** 手工挑的，没有自动发现
- V 方向的对比对是手写的 8 对，不可规模化

---

## 5. 下一步（按性价比）

1. **多事实已部分解决**（§10.26）：不同模板 + `--orth` → 5 条全中、零串扰，
   污染 7/20（2 条基线是 6/20）。下一步是把 N 推到 10+ 且把污染压回 ≤6/20，
   或引入语义级 holdout 判据来量化真实损伤
2. **方向自动发现**：从事实库自动生成对比对 → 方向才能规模化
3. **数字类属性**（人口/面积）测第二跳天花板：预期会崩，用来划清"记忆的边界"
4. **控制层**：不是置信度（已证伪），而是"检索命中 + 双向一致 + 淘汰"

---

## 6. 工具速查

| 工具 | 作用 |
|---|---|
| `tools/hebb_write.py` | `HebbWriter`：捕获 φ、算 ΔB、写入 |
| `tools/hebb_multifact.py` | 多事实实验：预筛 / 布局 / `--orth` / 验收 |
| `tools/hebb_deliver.py` | 赫布写入交付 + 端到端验收 |
| `tools/hebb_deliver_build.py` | 赫布构造（论文法：整块替换 MLP）|
| `tools/hebb_verify.py` | 只读验收任意已打包 GGUF |
| `tools/hebb_memory.py` | 运行时记忆层（分解式桥接）|
| `tools/hebb_kvblock.py` | K/V 事实块（KV 前缀）|
| `tools/retr_memory.py` | 激活检索记忆（无训练/无外部 embedding，L4+L6 φ 均值池化）|
| `tools/retr_ask.py` | 激活检索命令行：`--build` / 查询 / `--eval` |
| `tools/hebb_extract.py` | 反向提取 / 交付审计（SVD）|
| `tools/hebb_steer.py` | V 通道方向：干预 + 探针 |
| `tools/hebb_rerank.py` | 方向读出：分类 + 重排 |
| `tools/hebb_style.py` | 第二个方向（代码 vs 散文）|
| `tools/q1t_stream.py` | Q4T 流式引擎（`forward(force_kv, capture_kv, v_delta)`）|

## 7. 激活检索（§10.34，2026-10-26）

换词改写检索，**无训练、不引入外部 embedding 模型**：key 向量 = 模型第 4/6 层
FFN 激活的均值池化，检索 = 两层余弦求和。

| 口径 | 结果 |
|---|---|
| 真实事实池 N=490（90 查询，换词改写）| **80/90 = 88.9%** |
| capital / currency | **各 30/30** |
| language（`tongue` 这种完全换词）| 20/30（`official language of` 30/30）|
| 交付模块 `--eval` 复现 | 88.9%（与实验一致）|

```
python tools/retr_ask.py --eval
python tools/retr_ask.py "What city is the capital of Japan?"
```

成本：建索引 1.3 s/条（未批处理），索引 24 KB/条。
**与字符串记忆层（`hebb_memory.py`）互补**：精确命中走字符串，改写走激活检索。

## 8. "教会"的边界（§10.35–§10.37，2026-10-26）

零训练三条路全部实测关闭：固定 key 注入跨改写 ≤13%；运行时 query-keyed 注入退化为
logit 偏置（错配查询也命中 5/10）；只有外置激活索引能跨改写（88.9%，但知识在文件里）。
训练在本机不可行：139 ms/token 前向、训练步 ≈3.1~3.5×、360 条样本 52 min/epoch，
且 0.6B 的训练器不存在（`qxn_train.py` 无 GGUF/Qwen 路径）。**结论：不再追求"权重里的换词泛化"。**

## 10b. 检索的外部效度（§10.34b，2026-10-27）

27 条手工新问法（风格全不同）：top1 **81.5%**（与 88.9% 的差在噪声内，CI ±14pp），
top3 **96.3%**。5 次失败 4 次是近似平局（正确项第 2，分差 ≤0.004）。
**链路对改写风格稳健，但分数无标定** → 产品应展示 top-3 / 设 margin。

## 10. 真 RAG 链路可用（§10.39，2026-10-27）

检索对 → 生成端 **4/4** 答对；加 3 条干扰 6/6；编造事实能复述；无 context 时 0 次瞎编。
**瓶颈全在检索（language 类弱）**，不在生成。链路：`retr_ask.py` 索引 + 0.6B Q4T，零训练。

## 9. "从零 + 赫布"的判决（§10.38，2026-10-26）

冻结随机权重 + 闭式读出（ELM/广义赫布）：CE **7.72**（随机 7.79、unigram 5.45、
梯度训练 3.41）。**容量不是瓶颈，"表示"才是**——赫布只能当组件，不能替代训练。
复检（§10.38.5）：gain 1→10 无效（CE 7.711→7.725，有效秩 39→77），温度校准只救 0.46，
仍差 bigram（4.30）**3 nat**。旧说法"过度自信"更正为"欠自信"（最优 T=0.14<1）。
再复检（§10.38.6）：**logistic 读出**（只训读出，主体仍冻）test CE **5.044**，
低于 unigram 6.116 → "随机特征无信息"**错误**，应改为"信息不足以建模"；
但仍不及 bigram 4.297，故边界为：**过 bigram 必须训练主体**。

> ⚠ **Q1T/Q4T 陷阱**：`StreamEngine()` 默认加载 **Q1T**（`PACK_SLIM`）。
> 所有赫布结论都基于 **Q4T** → 新脚本必须显式 `slim=hebb_write.DEFAULT_SLIM`，
> 否则输出乱码（§10.14.5）。
