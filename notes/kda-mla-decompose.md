# KDA / MLA 拆解：它们是不可约的稠密墙，还是有重构空间？

> 2026-08-27 · 接续 MoE「先路由后搬运」实锤（见 independent-stack §14.2）
> 目标：判断 KDA 与 Gated MLA 两类注意力层能否复制 MoE 的「先算小权重、后精准搬运」模式

## 一、与 MoE 的本质差异

MoE 能拆，根源是**存在「小权重决定大权重取舍」的结构**：
- router（gate）= 7168×896 ≈ 6.4M 参数，常驻
- 它决定 896 个专家里读哪 16 个

**注意力层的致命不同：没有这种「取舍」结构。**
attention 的每个输入 token 都要用全部 Q/K/V/O 矩阵，没有「先选一部分」的余地。
→ KDA/MLA 在「搬运取舍」层面，是**不可约的稠密墙**。

## 二、但「不可约」不等于「不可压」——三张牌

### 牌 1：权重按 token 均匀使用 → 但可优化读取路径
- KDA/MLA 权重每 token 每层全用，无法稀疏读
- 但其投影矩阵是**行列固定的 GEMM**，读取可以：
  - 按 `b` 维度并行分片（batch 共享，只读一次）
  - 权重与激活复用（同一批 token 共享同一份权重，读一次算多次）
- **这是「共享」而非「取舍」** —— 不省单 token 流量，但省跨 token 流量

### 牌 2：KDA 循环状态小 → 可常驻 SRAM（前面 KDA 系列已讲）
- 循环状态 = O(d×d)，与序列长度无关，几 MB 级
- 但 **KDA 的权重（g_proj 门控投影等）仍然是稠密的，每 token 全读**

### 牌 3：量化 / 低精度（前面 QAT/MXFP4 已讲）
- 权重已 MXFP4，2.12 bit/weight
- 已把注意力层权重的「单位读取成本」压到最低
- 这是唯一的「搬运量」压缩手段，且已用尽

## 三、结论：KDA/MLA 是物理稠密墙，重构空间在「层外」不在「层内」

层内的 Q/K/V/O 投影，是每个 token 绕不过的稠密矩阵乘法。
**不能像 MoE 那样靠 router 取舍**，只能：
1. 用 batch 共享摊薄（改变不了单 token，改变整体吞吐）
2. 用 MXFP4 压单位成本（已用尽）
3. **层外思路**：KDA 循环状态常驻 + AttnRes 仅 8 层摘要 → 注意力本身的「存储」可省
   但注意力「权重」仍是稠密墙

## 三·五、latent MoE 的精确结构（重要更正，防记错账）

K3 是 **Stable LatentMoE**（sglang/waste 源码实锤）：
```
routed_expert_down_proj: 7168 → 3584   ← 稠密，所有专家共享
专家(896): 3584 → 3072 ×2，运行在 latent 空间  ← 唯一可按路由取舍的部分
routed_expert_up_proj: 3584 → 7168    ← 稠密，所有专家共享
RMSNorm before up_proj
```

**关键：down_proj / up_proj 是全体专家共享的稠密矩阵，每 token 全用。**
→ 它们属于「trunk 稠密墙」，已计入 trunk 36GB。
→ 「先路由后搬运」能省的**只有中间那 896 个专家**的读取，
  省幅 = 专家侧流量 × (880/896)，而不是省掉整层。
→ 专家 25.83GB 中按路由省读的，是「专家本体」（down/up 之外的中间段）。

## 四、对「捅破结构」的最终判断

- **MoE 专家：可捅破**（先路由后搬运，省 880/896）
- **KDA/MLA 注意力权重：不可捅破**（稠密墙，靠 batch 共享 + 已用尽的量化）
- **注意力状态：可省**（KDA 循环状态常驻，AttnRes 摘要 56KB）

→ 真正值得捅破的仍是 MoE 的「先路由后搬运」；注意力层是物理天花板。

## 五、数量化（待 T8 实测）

- 每 token 总流量 = 专家 25.83GB + trunk 36GB（量化后）
- 若「先路由后搬运」成立：专家侧能省的比例 = (880/896) × 命中精准度
- 理论省幅：专家流量最多降到 ~0.46GB（只读 16 专家的下界）→ 但受缓存/预取现实约束

## 六、提取 router 的实际读写依赖（本轮核心）

> 目标：把「算一个 token 的路由」钉死到「它到底碰了哪些权重张量、哪些 slice」，
> 精确回答：要拿到 top16，哪部分权重是绕不开的稠密墙，哪部分可以只读一片。

### 6.1 router 权重本身（极小，可完全常驻）

源码实锤（sglang `kimi_linear.py` / `kimi_k3.py`）：
```
gate = ReplicatedLinear(hidden_size=7168, num_experts=896, bias=False)
router_logits, _ = self.gate(hidden_states)
```
- **gate.weight：7168 × 896 ≈ 6.4M 参数**，无 bias
- 预测后处理仅：`e_score_correction_bias`(896 标量, selection only) + sigmoid + top16
- **→ gate.weight + correction_bias 是 router 的「所有权重」，
  合起来几十 MB，完全可以常驻内存，无需搬运**
- **这意味着：算路由本身，不需要任何专家权重，不需要任何 KDA/MLA 的 Q/K/V/O 权重。**

### 6.2 router 的输入依赖链（真正的墙在这）

```
router_logits = gate.weight ⊗ h_in
   h_in = post_attention_layernorm(attn_out)      # 入层向量
      attn_out = self_attn(KDA 或 Gated MLA)       # 本层注意力输出
         # 注意力 = Q/K/V/O 投影，全稠密，每 token 全读
      h_in（进层）出自 input_layernorm(h 前层)
```

**核心矛盾：**
- router 的**权重**（gate.weight）极小、可常驻、可独立提取 ✅
- 但 router 的**输入** h_in 依赖「本层完整注意力输出」，而注意力依赖本层 KDA/MLA 的稠密权重

→ **「提取 router 读写的依赖」的精确答案是：**
   router 真正独用的权重 = gate.weight + correction_bias（可常驻）；
   但 router 要工作，还需要「本层注意力的输出」h_in —— 这需要先读并算完本层 KDA/MLA 稠密权重。

### 6.3 有没有可能只提取「产生 h_in 的最小子集」？

两条路（都诚实标注代价）：

**路 A · 本层注意力算完才路由（现状，100% 精确）**
- 必须读：本层全部 Q/K/V/O（稠密）+ gate.weight
- 代价：注意力权重是绕不开的稠密墙
- 收益：路由精确，top16 精准

**路 B · 轻量化路由（跳过部分注意力）**
- 用更早的 h（如进层 h、或上一层的 h）直接喂 router，或用一个轻投影近似 h_in
- 不读/少读本层注意力权重 → 但路由是**近似**，top16 命中率 < 100%
- 这是「用 h 层预测 + routing-driven prefetch」的老路（前面 35.3% 命中实测）

**路 C · 精确提取 gate.weight 单独常驻 → 但喂它完整/近似 h_in**
- gate.weight 一定常驻（省掉它的搬运）
- h_in 要么走 A（精确，稠密墙），要么走 B（近似，省注意力权重读取）

### 6.4 结论

- **能被「提取」的 router 依赖 = gate.weight + correction_bias** —— 极小，常驻，这部分搬运直接归零
- **不能被提取的 = 本层注意力输出 h_in 的产生** —— 依赖 KDA/MLA 稠密权重，是物理墙
- **所以「先路由后搬运」的精确实义：**
  router（gate.weight 常驻）在**当前层注意力算完后瞬间**拿到 h_in → 立刻算出 top16 → **后续只精准搬运/download 这 16 个专家本体**（省掉 880/896 的专家读取）
- 唯一绕不开的稠密部分 = **注意力 Q/K/V/O 权重**（属于 trunk 36GB，本来就不按路由取舍）

→ **每 token 真正能被「先路由后搬运」省掉的，是专家本体 25.83GB 里的 (880/896)；注意力稠密墙（trunk 36GB 中）不变。**
→ 这是本轮拆解的最终、可量化结论。
