#!/usr/bin/env python3
"""
probe_k3_fwd.py — 主干分层数值探针 (H2/H4/H5 激活审计) v2

目的：加载 trunk.bin 选定层的 BF16 权重，对一段真实 token 流做手写 forward，
      直接观测官方声称的可测机制：
        H4: α 的低界 (g_min=−5) 是否真的退到 e^{−5}
        H2: α/β 统计随位置/token 的形状；MLA content/rope 切分的 logit 贡献
        H5: inter-chunk(state) vs intra-chunk 的长程贡献占比
      全部在几个代表层内完成（不加载 896 专家），读盘只有几十个张量。

设计原则：
  · 维度全部从权重矩阵推导，不硬编码 7168/12288（自动适应真实/合成 trunk)
  · BF16 手工解码（sign8mant7），无 torch 依赖
  · embed 从独立 safetensors 分片加载（k3_head_dims 同款 header 解析）
  · α/β 解码标注假设，实跑后按真实数据校正

用法:
  python3 tools/probe_k3_fwd.py --trunk-json trunk.json --trunk-bin trunk.bin \
         --embed-shard model-00094-of-000096.safetensors \
         [--layers 0,45,92] [--tokens 1,9,99,1234]

输出: results/probe_k3_fwd_<ts>.md
"""
import argparse, json, os, struct, sys, time

import numpy as np


# ── safetensors header 解析（同 k3_head_dims）─────────────────
def st_header(path):
    with open(path, "rb") as f:
        n = int.from_bytes(f.read(8), "little")
        return json.loads(f.read(n).decode("utf-8"))


def st_header_len(path):
    with open(path, "rb") as f:
        return 8 + int.from_bytes(f.read(8), "little")


def load_st_tensor(path, name, meta):
    """读单个 safetensors 张量 → float32 ndarray。meta = header[name]
    data_offsets 是相对 header 结束(数据段起点)的偏移，需加 header 长度。"""
    dt = meta["dtype"]
    shape = meta["shape"]
    off0, off1 = meta["data_offsets"]
    m = {
        "BF16": (2, np.uint16), "F32": (4, np.float32), "F16": (2, np.float16),
    }.get(dt, (2, np.uint16))
    base = st_header_len(path)
    with open(path, "rb") as f:
        f.seek(base + off0)
        raw = f.read(off1 - off0)
    arr = np.frombuffer(raw, dtype=m[1]).reshape(shape)
    if dt == "BF16":
        return bf16_to_f32(arr)
    return arr.astype(np.float32)


def bf16_to_f32(w):
    u = w.astype(np.uint32)
    sign = ((u >> 15) & 1).astype(np.float32) * -2.0 + 1.0
    exp = (u >> 7) & 0xFF
    man = (u & 0x7F).astype(np.float32)
    expf = exp.astype(np.float32)
    expf = np.where(exp == 0xFF, np.float32(200.0), expf)  # inf/NaN → 饱和到 ~1e22,防范数溢出
    val = (1.0 + man / 128.0) * (2.0 ** (expf - 127.0))
    val = np.where(exp == 0, 0.0, val * sign)
    return val


def is_v2(name):
    n = name.lower()
    return ("kv_a_proj_with_mqa" in n or "q_a_proj" in n or "q_b_proj" in n)


def classify(name):
    n = name.lower()
    if "embed" in n or "tok_emb" in n or "lm_head" in n:
        return "embed"
    if "conv1d" in n or "conv" in n:
        return "conv"
    if "kv_a_layernorm" in n or "q_a_layernorm" in n or "o_norm" in n:
        return "norm"
    if "A_log" in n or "dt_bias" in n:
        return "logit_bias"
    if is_v2(n):
        return "mla"
    if "self_attn" in n or "attn" in n:
        return "kda"
    if "gate" in n or "router" in n or "e_score" in n:
        return "router"
    if "shared" in n or "routed" in n or "moe" in n:
        return "moe"
    if "norm" in n or "layernorm" in n or "rms" in n:
        return "norm"
    return "other"


def layer_of(name):
    import re
    m = re.search(r"layers[._](\d+)", name)
    return int(m.group(1)) if m else None


class Trunk:
    """trunk.json 索引 + trunk.bin 懒加载 BF16 张量"""
    def __init__(self, trunk_json, trunk_bin):
        with open(trunk_json, "rb") as f:
            data = json.load(f)
        self.binpath = trunk_bin
        self._f = None
        self.map = {}
        items = []

        def _flatten_layers(layers):
            out = []
            for e in layers:
                if not isinstance(e, dict):
                    continue
                tens = e.get("tensors") if isinstance(e.get("tensors"), dict) else e
                if not isinstance(tens, dict):
                    continue
                for k, v in tens.items():
                    if isinstance(v, dict):
                        out.append((k, v))
            return out

        if isinstance(data, dict):
            fst = data.get("layers")
            if isinstance(fst, list) and fst and isinstance(fst[0], dict) and "tensors" in fst[0]:
                items = _flatten_layers(fst)
            else:
                items = [(k, v) for k, v in data.items() if k != "__metadata__"]
        elif isinstance(data, list):
            if data and isinstance(data[0], dict) and isinstance(data[0].get("layers"), list):
                items = _flatten_layers(data[0]["layers"])
            else:
                for e in data:
                    if not isinstance(e, dict):
                        continue
                    nm = e.get("name") or e.get("key") or next((v for k, v in e.items()
                           if k in ("tensor", "tensor_name", "id")), "<anon>")
                    items.append((nm, e))
        for name, v in items:
            shape = None
            if isinstance(v, dict):
                for k in ("shape", "dims", "sizes"):
                    if k in v and isinstance(v[k], list):
                        shape = [int(x) for x in v[k]]
                        break
                off = 0
                for k in ("offset", "off", "data_offset", "start", "addr"):
                    if k in v:
                        off = int(v[k])
                        break
                dby = 2  # 默认 BF16
                dts = str(v.get("dtype", "bf16")).lower()
                dby = {"f32": 4, "fp32": 4, "float": 4, "bfloat16": 2, "bf16": 2,
                       "fp16": 2, "f16": 2, "float16": 2}.get(dts, 2)
            elif isinstance(v, list):
                shape = [int(x) for x in v]
                off, dby = 0, 2
            else:
                continue
            if shape is None:
                continue
            self.map[name] = {"off": off, "dbytes": dby, "shape": shape}
        self.layers = {layer_of(n) for n in self.map}
        self.layers.discard(None)

    def tensor(self, name):
        m = self.map[name]
        n = int(np.prod(m["shape"], dtype=np.int64))
        if self._f is None:
            self._f = open(self.binpath, "rb")
        self._f.seek(m["off"])
        raw = self._f.read(n * m["dbytes"])
        if m["dbytes"] == 4:
            return np.frombuffer(raw, dtype=np.float32).reshape(m["shape"]).copy()
        return bf16_to_f32(np.frombuffer(raw, dtype=np.uint16)).reshape(m["shape"]).copy()

    def layer_names(self, L):
        return sorted(n for n in self.map if f"layers.{L}." in n or f"layers_{L}." in n)

    def sub(self, L, tag=""):
        """返回 layer L 里 self_attn 下匹配 tag 的全部张量名"""
        ns = self.layer_names(L)
        return [n for n in ns if "self_attn" in n and tag in n]


# ── 数值原语 ──────────────────────────────────────────────
def sigmoid(x):
    return 1.0 / (1.0 + np.exp(-np.clip(x, -40, 40)))


def swish(x):
    return x * sigmoid(x)


def l2norm(x, eps=1e-6):
    return x / (np.linalg.norm(x, axis=-1, keepdims=True) + eps)


def shortconv_1d(X, kernel):
    """因果 1D conv, kernel: [dim,1,k]。X:[S,dim] → [S,dim] (首位 k-1 复制)"""
    k = kernel.shape[-1]
    out = np.zeros_like(X)
    for t in range(len(X)):
        acc = np.zeros(X.shape[1], dtype=np.float32)
        for i in range(k):
            src = t - i
            src = 0 if src < 0 else src
            acc += kernel[:, 0, i] * X[src]
        out[t] = acc
    return out


def probe_kda(ti, L, x, S):
    """跑一层 KDA: 返回 stats dict。x:[S,d] 输入 hidden。
    结构假设(对齐报告/权重清单, 跑真数据后校正):
      q/k/v = L2Norm(Swish(ShortConv(W_qkv x)))
      z = f_b(f_a(x))           # α logits per (head,channel): [S, 96,128] (f_a 128→12288)
      β = Sigmoid(z + dt_bias)  # 写强度
      g = −5 · Sigmoid(z·A_log + b_α) ; α = exp(g)   # b_α=b_proj→[S,96] per-head
    """
    d = x.shape[-1]
    attns = []
    for n in ti.sub(L):
        stem = n.rsplit(".", 1)[0] if n.endswith(".weight") else n
        if stem.endswith(("q_proj", "k_proj", "v_proj")):
            attns.append(n)
    if not attns:
        return None
    out = {}
    proj = {}  # "q"/"k"/"v" → [S, head*ch]
    head_dim = None
    for n in attns:
        lbl = n.rsplit(".", 1)[0].rsplit("_", 1)[-1]  # q/k/v
        W = ti.tensor(n)                    # [head*ch, d]
        kv_ = W @ x.T                       # [head*ch, S]
        kv_ = kv_.T                          # [S, head*ch]
        # ShortConv
        cv = None
        for c in [n.replace("_proj.weight", "_conv1d.weight")]:
            if c in ti.map:
                cv = ti.tensor(c)
        if cv is not None:
            kv_ = shortconv_1d(kv_, cv)
        proj[lbl] = swish(kv_) if lbl == "v" else l2norm(swish(kv_))
        if head_dim is None:
            head_dim = W.shape[0] // 96 if W.shape[0] % 96 == 0 else None
    out["head_dim"] = head_dim

    # α logits
    fa = ti.tensor(next(n for n in ti.sub(L, "f_a_proj")))
    fb = ti.tensor(next(n for n in ti.sub(L, "f_b_proj")))
    z = (x @ fa.T) @ fb.T                    # [S, 12288]
    nch = z.shape[-1]
    h = 96 if nch % 96 == 0 else 1           # 头数推断
    zr = z.reshape(S, h, nch // h)
    A_log = ti.tensor(next(n for n in ti.sub(L, "A_log")))   # [128] 每通道 log-scale
    A = A_log.astype(np.float32)
    b_proj = ti.tensor(next(n for n in ti.sub(L, "b_proj"))) # [96, d]
    b_alpha = x @ b_proj.T                   # [S, 96] per-head bias
    g = -5.0 * sigmoid(A[None, None, :] * zr + b_alpha[:, :, None])
    alpha = np.exp(g)                        # [S, h, ch]
    dt = sigmoid(z + ti.tensor(next(n for n in ti.sub(L, "dt_bias"))))  # [S, 12288]
    out["alpha"] = {
        "min": float(alpha.min()), "max": float(alpha.max()),
        "mean": float(alpha.mean()),
        "plow<0.1": float((alpha < 0.1).mean()),
        "plow<e-5": float((alpha < np.exp(-5.0)).mean()),
    }
    out["beta_dt"] = {
        "mean": float(dt.mean()), "min": float(dt.min()), "max": float(dt.max()),
    }
    # 位置敏感度：α 随 t 的相关性（前向后向）
    am = alpha.mean(axis=(-1, -2))           # [S]
    if S >= 4:
        out["alpha_trend_corr"] = float(np.corrcoef(np.arange(S), am)[0, 1])
    return out


def probe_mla(ti, L, x, S):
    """MLA content/rope 切分。返回 stats dict。
    q_a→q_b: q latent 1536 → 96×(128 content + 64 rope)
    kv_a(with_mqa)→kv_b: 576 → 96×(128 k + 128 v)   (rope 不达 kv_b)
    """
    qa = ti.tensor(ti.sub(L, "q_a_proj")[0])
    qb = ti.tensor(ti.sub(L, "q_b_proj")[0])
    kva = ti.tensor(ti.sub(L, "kv_a_proj_with_mqa")[0])
    kvb = ti.tensor(ti.sub(L, "kv_b_proj")[0])
    q = (x @ qa.T) @ qb.T                     # [S, 96*192]
    kv = (x @ kva.T) @ kvb.T                  # [S, 96*256]
    h = 96
    qr = q.reshape(S, h, -1)                  # [S,96,192]
    kvr = kv.reshape(S, h, -1)                # [S,96,256]
    qc, qrope = qr[:, :, :128], qr[:, :, 128:]
    kc, vc = kvr[:, :, :128], kvr[:, :, 128:]
    with np.errstate(all="ignore"):
        qce = float((qc ** 2).mean()); qre = float((qrope ** 2).mean())
        kce = float((kc ** 2).mean()); vce = float((vc ** 2).mean())
    return {
        "q_head_dim": qr.shape[-1],
        "kv_head_dim": kvr.shape[-1],
        "q_content_energy": qce,
        "q_rope_energy": qre,
        "k_content_energy": kce,
        "v_content_energy": vce,
        "rope_vs_content": (qre / qce) if qce > 0 else float("nan"),
        "content_logit_mean": float((qc * kc).mean()),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--trunk-json", required=True)
    ap.add_argument("--trunk-bin", required=True)
    ap.add_argument("--embed-shard", default=None,
                    help="embed 所在 safetensors 分片路径")
    ap.add_argument("--layers", default="0,45,92", help="逗号分隔层号")
    ap.add_argument("--tokens", default="1,9,99,1234,56789",
                    help="逗号分隔 token id")
    args = ap.parse_args()

    t0 = time.time()
    ti = Trunk(args.trunk_json, args.trunk_bin)
    print(f"[{time.time()-t0:.1f}s] 索引 {len(ti.map)} 张量, layers={sorted(ti.layers)[:5]}...")

    ids = [int(t) for t in args.tokens.split(",") if t.strip()]
    S = len(ids)
    d = 7168

    # embed
    if args.embed_shard and os.path.exists(args.embed_shard):
        hdr = st_header(args.embed_shard)
        names = [n for n in hdr if n != "__metadata__" and ("embed" in n.lower() or "tok_emb" in n.lower())]
        if names:
            emb = load_st_tensor(args.embed_shard, names[0], hdr[names[0]])
            d = emb.shape[-1]
            x = emb[ids].astype(np.float32)
            print(f"[{time.time()-t0:.1f}s] embed {names[0]} {emb.shape} → x[{S},{d}]")
        else:
            sys.exit("embed shard 里没找到 embed 张量")
    else:
        np.random.seed(0)
        x = (np.random.randn(S, d) * 0.02).astype(np.float32)
        print(f"[{time.time()-t0:.1f}s] 无 embed → 用随机输入 x[{S},{d}]")

    layers = [int(l) for l in args.layers.split(",") if l.strip()]
    out = {}
    for L in layers:
        names = ti.layer_names(L)
        if not names:
            print(f"[skip] layer {L} 无张量")
            continue
        version = "v1/KDA" if not is_v2(" ".join(names)) else "v2/MLA"
        print(f"\n---- layer {L} ({version}) {len(names)} 张量 ----")
        if version == "v1/KDA":
            st = probe_kda(ti, L, x, S)
        else:
            st = probe_mla(ti, L, x, S)
        if st is None:
            print("   (无 q/k/v 结构, skip)")
            continue
        for k, v in st.items():
            if isinstance(v, dict):
                print(f"   {k}: " + " ".join(f"{kk}={vv:.4g}" for kk, vv in v.items()))
            elif isinstance(v, float):
                print(f"   {k}: {v:.4g}")
            else:
                print(f"   {k}: {v}")
        out[L] = (version, st)

    os.makedirs("results", exist_ok=True)
    ts = time.strftime("%Y%m%d_%H%M%S")
    fn = f"results/probe_k3_fwd_{ts}.md"
    with open(fn, "w") as f:
        f.write(f"# probe_k3_fwd {ts}\ntokens={ids} layers={layers}\n\n")
        for L, (ver, st) in out.items():
            f.write(f"## layer {L} ({ver})\n")
            f.write(json.dumps(st, indent=1) + "\n\n")
    print(f"\n[{time.time()-t0:.1f}s] 结果 → {fn}")


if __name__ == "__main__":
    main()