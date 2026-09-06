# Kimi K3 — Architecture Baseline

**Source:** `k3_tech_report.pdf` (MoonshotAI/Kimi-K3, 47 pages) — first download 2026-09-06.
Extracted text: `k3_tech_report.extracted.txt`.
Primary attention reference: Kimi Linear, arXiv:2510.26692.

This file separates **official disclosed facts** from **our inferences to verify**.
All line numbers refer to `k3_tech_report.extracted.txt`.

---

## 1. Canonical model summary (official, Table 1 / Model Summary)

| Item | K2 | K3 |
|---|---|---|
| Architecture | MoE | MoE |
| #Layers | 61 | 93 (+52%) |
| Total Params | 1.04T | **2.78T** |
| **Activated Params** | 32.6B | **104.2B** |
| Hidden Dim | 7,168 | 7,168 (=) |
| **Latent MoE Dim** | – | **3,584 (0.5×)** |
| MoE Hidden / Expert | 2,048 | 3,072 (+50%) |
| Routed Experts | 384 | 896 (+133%) |
| Experts Active / Token | 8 | 16 (+100%) |
| Shared Experts | 1 | **2** (+100%) |
| Attention Heads | 64 | 96 (+50%) |
| Dense Layers | 1 | 1 |
| Vocab | 160K | 160K |
| Attn Composition | 61 MLA | **69 KDA + 24 Gated MLA** |
| Activation | SwiGLU | SiTU-GLU |
| Latent Context Len | 128K | 1M (8×) |
| MTP Layers | 1 | 1 |
| ViT | – | 401M, 27 layers, patch 14, 12 heads |

**Block structure:** every block = 3 KDA + 1 Gated-MLA (3:1), plus a final Gated-MLA at backbone end
(so the final layer is always global attention).

---

## 2. Official disclosures that change our earlier assumptions

1. **Quantization is NOT uniform.** Only *routed-expert* weights go to MXFP4;
   activations MXFP8. **All non-expert components (attention projections, latent MoE
   projections, shared experts, MoE routers) stay in higher precision** (§4.1.4, line ~1013).
   ⇒ Our "trunk → 8bit (55G)" is *more aggressive than the vendor ships*. Vendor never
   quantized attention/trunk to 8bit.

2. **Speculative decoding is built-in.** Model is pre-trained with **1 MTP layer**, then
   fine-tuned into an **EAGLE-3-style draft model** (target frozen; draft = a single decoder
   layer structurally matching the MTP layer). Draft fuses features from the **1st, 4th, and
   final AttnRes blocks**. Trained by directly maximizing the LK acceptance-rate loss
   (§4.1.4, lines ~1019-1043). ⇒ vendor validates the speculative-decode line we pursued.

3. **KDA state is fixed-size; only MLA has growing KV.** KDA keeps a bounded recurrent
   matrix state S_t ∈ R^{d_k × d_v}. Only the 24 Gated-MLA layers cache tokens.
   ⇒ "KV read outgrows weights at long context" does NOT apply to KDA layers.

---

## 3. KDA (official equations)

**Recurrence (Eq.1, per hidden head):**

    S_t = (I − β_t · k_t·k_t^T) · Diag(α_t) · S_{t−1} + β_t · k_t · v_t^T
    ~o_t = S_t^T · q_t

    q_t, k_t = L2Norm(Swish(ShortConv(W^h_{q/k} x_t)))    ∈ R^{d_k}
    v_t      = Swish(ShortConv(W^h_v x_t))                ∈ R^{d_v}
    β_t      = Sigmoid(W^h_β x_t)                          ∈ (0,1)   [write strength]
    z_t      = W^↑_α W^↓_α x_t + b^h_α                    ∈ R^{d_k} [decay logits]

d_k = d_v = 128 (per Kimi Linear; check K3 weights offline).

**K3-specific changes vs Kimi Linear (Fig. 3, §2.1.1):**
- **Lower-bounded decay:** log-decay g_t = g_min · Sigmoid(e^{A_h} z_t) ∈ (g_min, 0),
  g_min = −5 fixed; A_h = learnable per-head log-scale (init 0); A_h init follows GDN/Mamba-2.
  ⇒ bounds α ∈ (e^{−5}, 1), cumulative over a 16-token tile ∈ (−80, 0), reciprocal < e^80
  (BF16 range) → **all causal tiles use dense Tensor-Core GEMMs** (Kimi Linear's old diagonal
  position-pair path eliminated).
- **Full-rank output gate (Eq.6):** y_t = W_o [ Sigmoid(W_g x_t) ⊙ RMSNorm(~o_t) ].
  (Kimi Linear used a low-rank gate.)
- Chunkwise form (Eq.4) with inter-chunk (reads S_t) + intra-chunk (Tril) terms is same as
  Kimi Linear. This inter/intra split is the primary place to *probe* how much "long-range"
  actually flows through state vs intra-chunk.

---

## 4. Gated MLA (official)

- DeepSeek-V2 MLA: compress KV into latent c_t = W_c x_t; reconstruct keys/values via learned
  up-projections. Cuts KV-cache; keeps global token-to-token attention.
- **NoPE:** K3 applies **No Position Encoding** to ALL MLA layers. Queries/keys carry no explicit
  position. KDA layers are entirely responsible for position/recency (§2.1.2 fnd lines 481-485).
  ⇒ The claim to test: MLA output should be position-insensitive; if we find systematic
  position bias in MLA, that contradicts the design.
- Full-rank channel-wise output gate (Eq.7), like KDA.

---

## 5. Attention Residuals (AttnRes, §2.2)

Full: per layer l, pseudo-query q_l = w_l ∈ R^d; keys/values = {h_1 (embedding), f_i(h_i)}.
Softmax kernel ϕ(q,k) = exp(q^T RMSNorm(k)); output h'_l = Σ α_{i→l} v_i. O(L²d) arithmetic.

**K3 uses Block AttnRes:** 93 layers → **8 blocks × 12 layers + 1 partial block** (+embedding
= 9 blocks). Within block: layer outputs summed to one repr; across blocks: full attention over
N block reprs only. Drops cost O(Ld) → O(Nd). Official: N≈8 recovers most benefit.

---

## 6. Stable LatentMoE (§2.3)

LatentMoE separates full width d from routed width ℓ = Latent MoE Dim = 3,584 (0.5× hidden).

    z = W^↓ x ∈ R^ℓ          [latent down-projection]
    u = Σ_{i∈T_k(x)} p_i E_routed_i(W^↓ x)
    y = Σ_{j=1}^{N_s} E_shared_j(x) + W^↑ RMSNorm(u)

- N_s shared experts = **2** (full-width), fixed every layer.
- 896 routed, 16 active → sparsity 56.
- **SiTU-GLU** (Eq.12): softcap(x,β)=β tanh(x/β) applied to gate (β1=4) and up (β2=25) branches
  to bound activation growth (SwiGLU unbounded).
- RMSNorm before W^↑ (normalized latent) — stable under extreme sparsity.
- **Quantile Balancing** (QB): load balance via quantiles of routing scores, no aux loss.

---

## 7. Speculative decoding / MTP (official, §4.1.4)

- Pre-trained 1 MTP layer (mirrors a backbone block). Fine-tuned → EAGLE-3-style draft
  (single decoder layer matching MTP).
- Draft input fuses **low (1st AttnRes block), mid (4th), high (final)** features; concat +
  bias-free projection W_E3 (init [0 0 I] ⇒ initially equals high-level feature h_h).
- Target frozen; only draft layer + feature-fusion projection updated.
- Draft unrolled 7 steps in training (target features for newest pos unavailable past step 1).
- Loss: **L_LK = −log Σ_x min(p(x), q(x))** — directly the per-token acceptance rate,
  temperature 1, no CE term.
- Both draft and target use MXFP4 experts / MXFP8 activations in post-training.

---

## 8. Training / other notes

- Per-Head Muon optimizer + weight clipping; cosine LR, 1% warmup, wd 0.1.
- Pretrain start 8k ctx → 64k → (long-context phase) up to 1M.
- Flash-attention output kept in FP32 during training (corrects biased rounding); kernel
  re-designed to overlap output tile with KV staging buffers.
- Native multimodal from start (interleaved vision+text, single next-token objective).
- 2.5× scaling-efficiency vs K2 (fitted law, Fig. 7).

---

## 9. Open / to-verify items (our inference, NOT official)

- [ ] d_k = d_v actual value in K3 weights (Kimi Linear used 128; K3 head dim 7168/96 = 74.67
      is NOT an integer ⇒ K3 does not use plain 96 heads of equal dim; must read weights).
- [ ] Real state size S_t (R^{d_k × d_v}) and how it maps onto 7168 hidden / 96 heads.
- [ ] Actual composition of OUR 55G "trunk" — which tensors, and at what precision. Official
      keeps attention/trunk/shared/router high-precision; we compressed trunk to 8bit.
- [ ] 130 s/token measurement: does it reflect storage-pressure (working set not resident),
      and does KV now only grow on 24 MLA layers?
- [ ] Whether MBA/MLA attention outputs show position dependence (NoPE claim test).
- [ ] Whether the inter-chunk (state) vs intra-chunk (Tril) split actually carries the
      long-range signal, layer by layer.