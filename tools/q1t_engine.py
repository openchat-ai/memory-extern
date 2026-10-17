#!/data/data/com.termux/files/usr/bin/python3
"""q1t_engine.py — 1-bit 无壳推理引擎 (Qwen3-0.6B, QxT packslim 格式).

输入: qxt_pack_q1t.py 生成的 QXTSLIM 文件(每 32 权重 {1B scale; 4B bit}, 1.25bpw)
      + 源 GGUF(token_embd / fp32 norm / 超参)。
纯 numpy 前向, 不依赖 llama.cpp / T-MAC。
"""
import os, sys, json, math, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_fidelity_scan as Q

MAGIC = b"QXTSLIM1\n"
DATA_OFF = 17  # magic(9) + jlen(4) + pad(4)
QK = 32

PACK_SLIM = ("/data/data/com.termux/files/home/models/qxt/"
             "rStar-Coder-Qwen3-0.6B.Q8_0-Q1T_packslim.gguf")
SRC = "/data/data/com.termux/files/home/models/rStar-Coder-Qwen3-0.6B.Q8_0.gguf"


def read_packslim(path):
    """-> (cb, meta, {name: (offset, dims)})"""
    with open(path, "rb") as f:
        magic = f.read(9)
        assert magic == MAGIC, magic
        jlen = int.from_bytes(f.read(4), "little")
        f.seek(os.path.getsize(path) - jlen)
        meta = json.loads(f.read(jlen).decode())
    cb = np.array([float(meta.get("cb_neg", -0.34188)),
                   float(meta.get("cb_pos", 0.34188))]) if "cb_neg" in meta else Q.lloyd_cb(
        np.array([[0.1]]), 1)  # fallback
    # 打包文件本身不带 cb, 由 meta 记录; 若缺失则用固定值(与打包一致)
    if "cb_neg" not in meta:
        cb = np.array([-0.34188, 0.34188])
    by_name = {t["name"]: t for t in meta["tensors"]}
    return cb, meta, by_name


def dequant_packslim(buf, cb, b=1):
    """(N, 5) bytes -> (N, 32) fp32: scale_table[sc] * cb[bit]."""
    sc = buf[:, 0].astype(np.int64)
    bits = np.unpackbits(np.ascontiguousarray(buf[:, 1:5]), axis=1,
                         bitorder="little")[:, :32]
    d = Q.scale_table()[sc].astype(np.float32)          # (N,)
    vals = np.where(bits == 1, cb[1], cb[0]).astype(np.float32)  # (N,32)
    return d[:, None] * vals


def load_packslim_tensor(path, entry, cb, dtype=np.float32):
    n_in, n_out = entry["dims"]
    nb = int(n_in * n_out) // QK
    nb_bytes = nb * 5
    with open(path, "rb") as f:
        f.seek(entry["offset"])
        raw = f.read(nb_bytes)
    buf = np.frombuffer(raw, dtype=np.uint8).reshape(nb, 5)
    w = dequant_packslim(buf, cb).reshape(n_in, n_out).astype(dtype)
    return w


def rmsnorm(x, w, eps):
    return x * (1.0 / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + eps)) * w


def build_rope(head_dim, n_ctx, freq_base, dtype=np.float32):
    inv = 1.0 / (freq_base ** (np.arange(0, head_dim, 2, dtype=np.float32) / head_dim))
    pos = np.arange(n_ctx, dtype=np.float32)
    ang = pos[:, None] * inv[None, :]
    return np.cos(ang).astype(dtype), np.sin(ang).astype(dtype)


def apply_rope(x, cos, sin, pos):
    """x (T, nh, hd); cos/sin (n_ctx, hd/2). Qwen3/NeoX 风格: 前后半分配对."""
    T, nh, hd = x.shape
    h2 = hd // 2
    x1 = x[..., :h2]
    x2 = x[..., h2:]
    c = cos[pos][:, None, :]
    s = sin[pos][:, None, :]
    return np.concatenate([x1 * c - x2 * s, x1 * s + x2 * c], axis=-1)


class Q1TEngine:
    def __init__(self, slim=PACK_SLIM, src=SRC, n_ctx=2048, fp16=True):
        self.slim, self.src = slim, src
        self.kv, self.infos, self.ds = M.read_gguf(src)
        k = self.kv
        self.n_layer = k["qwen3.block_count"]
        self.n_embd = k["qwen3.embedding_length"]
        self.n_ff = k["qwen3.feed_forward_length"]
        self.n_head = k["qwen3.attention.head_count"]
        self.n_kv = k["qwen3.attention.head_count_kv"]
        self.hd = k["qwen3.attention.key_length"]
        self.eps = float(k["qwen3.attention.layer_norm_rms_epsilon"])
        self.freq = float(k["qwen3.rope.freq_base"])
        self.n_vocab = len(k["tokenizer.ggml.tokens"])
        self.tok_list = k["tokenizer.ggml.tokens"]
        self.tok_to_id = {t: i for i, t in enumerate(self.tok_list)}
        dt = np.float16 if fp16 else np.float32
        cb, meta, by = read_packslim(slim)
        self.cb = cb
        t0 = time.time()
        self.w = {}
        # 从源 GGUF 读 fp32 norm + token_embd
        for t in self.infos:
            if t.type == 0:
                n = int(np.prod(t.dims))
                raw = M.tensor_slice(src, self.ds + t.offset, 0, n * 4)
                self.w[t.name] = np.frombuffer(raw, dtype=np.float32).reshape(
                    t.dims).astype(dt)
            elif t.name == "token_embd.weight":
                n_in, n_out = t.dims
                qk = M.BLOCK_ELEMS[M.GGML_TYPE_Q8_0]
                nb = int(n_in * n_out) // qk
                w = M.dequant_blocks(src, t, self.ds, 0, nb).reshape(
                    n_in, n_out).astype(dt)
                self.w[t.name] = w
        # 从 packslim 读 Q1T 权重
        nq = 0
        for name, e in by.items():
            if "offset" in e and e.get("bytes", 0) > 0:
                self.w[name] = load_packslim_tensor(slim, e, cb, dt)
                nq += 1
        print(f"[load] {nq} Q1T tensor + norms/embd  {time.time()-t0:.1f}s", file=sys.stderr)
        self.cos, self.sin = build_rope(self.hd, n_ctx, self.freq, dt)

    def encode(self, text):
        """最简 BPE: 按空格/字符 greedy longest-match (足够跑测试 prompt)."""
        ids = []
        i = 0
        while i < len(text):
            matched = False
            for j in range(len(text), i, -1):
                if text[i:j] in self.tok_to_id:
                    ids.append(self.tok_to_id[text[i:j]]); i = j; matched = True; break
            if not matched:
                # fallback: byte token
                ids.append(self.tok_to_id.get(text[i],
                          self.tok_to_id.get("<0x%02X>" % ord(text[i]), 0)))
                i += 1
        return ids

    def decode(self, ids):
        return "".join(self.tok_list[i] for i in ids)

    def forward(self, toks, pos=0):
        T = len(toks)
        nh, nkv, hd = self.n_head, self.n_kv, self.hd
        W = self.w
        dt = W["token_embd.weight"].dtype
        x = W["token_embd.weight"][:, toks].T.astype(dt)   # (T, embd)
        cos, sin = self.cos[pos:pos+T], self.sin[pos:pos+T]
        seq = np.arange(T)
        rep = nh // nkv
        for i in range(self.n_layer):
            p = f"blk.{i}."
            h = rmsnorm(x, W[p+"attn_norm.weight"], self.eps)
            q = (h @ W[p+"attn_q.weight"].astype(dt)).reshape(T, nh, hd)
            kk = (h @ W[p+"attn_k.weight"].astype(dt)).reshape(T, nkv, hd)
            vv = (h @ W[p+"attn_v.weight"].astype(dt)).reshape(T, nkv, hd)
            q = rmsnorm(q, W[p+"attn_q_norm.weight"], self.eps)
            kk = rmsnorm(kk, W[p+"attn_k_norm.weight"], self.eps)
            q = apply_rope(q, cos, sin, seq)
            kk = apply_rope(kk, cos, sin, seq)
            kk = np.repeat(kk, rep, axis=1)
            vv = np.repeat(vv, rep, axis=1)
            sc = np.einsum("qhd,khd->hqk", q, kk) / math.sqrt(hd)   # (nh, Tq, Tk)
            mask = np.triu(np.ones((T, T), bool), 1)[None]
            sc = np.where(mask, -1e9, sc)
            p_ = np.exp(sc - sc.max(axis=-1, keepdims=True))
            p_ = p_ / p_.sum(axis=-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", p_, vv).reshape(T, nh * hd)
            o = o @ W[p+"attn_output.weight"].astype(dt)
            x = x + o
            h = rmsnorm(x, W[p+"ffn_norm.weight"], self.eps).astype(dt)
            g = h @ W[p+"ffn_gate.weight"].astype(dt)
            u = h @ W[p+"ffn_up.weight"].astype(dt)
            a = g / (1.0 + np.exp(-g)) * u
            d = a @ W[p+"ffn_down.weight"].astype(dt)
            x = x + d
        x = rmsnorm(x, W["output_norm.weight"], self.eps)
        return x @ W["token_embd.weight"].astype(dt)   # (T,1024)@(1024,V)=(T,V)

    def generate(self, prompt, n_new=32, temperature=0.8, seed=0, top_k=0):
        rng = np.random.default_rng(seed)
        ids = self.encode(prompt)
        t0 = time.time()
        out_ids = []
        for _ in range(n_new):
            lg = self.forward(np.array(ids, dtype=np.int64))[-1].astype(np.float64)
            lg = lg / temperature
            lg = lg - lg.max()
            p = np.exp(lg); p /= p.sum()
            if top_k > 0:
                idx = np.argpartition(p, -top_k)[-top_k:]
                p2 = p[idx]; p2 /= p2.sum()
                nid = int(rng.choice(idx, p=p2))
            else:
                nid = int(rng.choice(self.n_vocab, p=p))
            ids.append(nid); out_ids.append(nid)
        dt = time.time() - t0
        return out_ids, dt, n_new


if __name__ == "__main__":
    eng = Q1TEngine()
    print("vocab", eng.n_vocab, "layer", eng.n_layer, "cb", eng.cb)
    ids = eng.encode("hi")
    print("tokens('hi') =", ids, [eng.tok_list[i] for i in ids])
    lg = eng.forward(np.array(ids))
    print("logits shape", lg.shape, "max", float(lg.max()))
    top = np.argsort(lg[-1])[::-1][:8]
    print("top8:", [(eng.tok_list[i], round(float(lg[-1][i]), 2)) for i in top])