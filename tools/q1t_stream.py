#!/data/data/com.termux/files/usr/bin/python3
"""q1t_stream.py — 1-bit 无壳流式推理引擎 (Qwen3-0.6B, QxT packslim 格式).

核心原则 (用户出发点): Q1T 不解压、只有移位。每 32 元素块 = {1B scale;
4B bit},值 = scale_table[sc] * (±0.34188)。阻塞加性 GEMM:
  y[t, j] = SUM_k x[t,k] * W[k,j]
  W[k,j] 块展开: 对每个 (in 行, out 块) 组合读 5B, 块贡献 =
      scale * 0.34188 * SUM_{32}( (2*bit-1) * x[t, in] )   -- in 维收缩
      OR  按 in 行取 x 标量, 对 32 个 out 槽各加/减 x[t,in]*scale*0.34
权重永不物化成 float 数组; 内存 ≈ 69MB 文件 + T×in 激活。
"""
import os, sys, json, math, time
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_fidelity_scan as Q

MAGIC = b"QXTSLIM1\n"

PACK_SLIM = ("/data/data/com.termux/files/home/models/qxt/"
             "rStar-Coder-Qwen3-0.6B.Q8_0-Q1T_packslim.gguf")
SRC = ("/data/data/com.termux/files/home/models/"
       "rStar-Coder-Qwen3-0.6B.Q8_0.gguf")

CB = np.array([-0.34188, 0.34188], np.float32)
QK = 32
SC_TAB = Q.scale_table().astype(np.float32)


def read_packslim(path):
    with open(path, "rb") as f:
        magic = f.read(9)
        assert magic == MAGIC, magic
        jlen = int.from_bytes(f.read(4), "little")
        f.seek(os.path.getsize(path) - jlen)
        meta = json.loads(f.read(jlen).decode())
    return meta, {t["name"]: t for t in meta["tensors"]}


class SlimMat:
    """Bare-hosted streaming GEMM: y = x @ W, W 以 (scale+bits) 块流式读取.

    块布局: 整个 tensor 按 ne0(in) 最快切 32 元素块, 文件顺序 = GGUF 元素序。
    dims=(n_in, n_out) row-major 时, 块 b 内 32 个元素沿 out 推进:
      in  = b // (n_out//32), j0 = (b % (n_out//32)) * 32.
    """

    def __init__(self, path, entry):
        self.path = path
        self.n_in, self.n_out = entry["dims"]
        self.off = entry["offset"]
        self.nb = (self.n_in * self.n_out) // QK
        self.tot = self.nb * 5
        self.dtype = np.float32

    def matmul(self, x):
        """x (T, n_in) -> (T, n_out).

        块布局: GGUF ne0=in 最快 → 每 32 连续 in 元素一块, 同一 out 列的
        (n_in//32) 个块在文件里连续。按列分批: 读 chunk 列的全部块 →
        Wcol (n_in, B) 一次 matmul。权重只以 (scale+bit) 形式读取, 永不全量物化。
        """
        n_in, n_out = self.n_in, self.n_out
        T = x.shape[0]
        blocks_per_col = n_in // QK
        y = np.zeros((T, n_out), np.float32)
        B = 64  # 每批处理 64 个 out 列
        with open(self.path, "rb") as f:
            for j0 in range(0, n_out, B):
                nb = min(B, n_out - j0)
                f.seek(self.off + j0 * blocks_per_col * 5)
                raw = f.read(nb * blocks_per_col * 5)
                buf = np.frombuffer(raw, np.uint8).reshape(nb, blocks_per_col, 5)
                sc = SC_TAB[buf[:, :, 0].astype(np.int64)]          # (B, c)
                bits = np.unpackbits(np.ascontiguousarray(buf[:, :, 1:]),
                                     axis=2, bitorder="little")[:, :, :32]
                sign = np.where(bits == 1, CB[1], CB[0])            # (B, c, 32)
                wcol = (sc[:, :, None] * sign).reshape(nb, n_in).T  # (n_in, B)
                y[:, j0:j0 + nb] = x @ wcol.astype(np.float32)
        return y


def rmsnorm(x, w, eps):
    return x * np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + eps) * w


def build_rope(head_dim, n_ctx, freq_base, dtype=np.float32):
    inv = 1.0 / (freq_base ** (np.arange(0, head_dim, 2, dtype=np.float32) / head_dim))
    ang = np.arange(n_ctx, dtype=np.float32)[:, None] * inv[None, :]
    return np.cos(ang).astype(dtype), np.sin(ang).astype(dtype)


def apply_rope(x, cos, sin, pos):
    T, nh, hd = x.shape
    p = x.reshape(T, nh, hd // 2, 2)
    x0, x1 = p[..., 0], p[..., 1]
    c, s = cos[pos][:, None, :], sin[pos][:, None, :]
    return np.stack((x0 * c - x1 * s, x0 * s + x1 * c), axis=-1).reshape(T, nh, hd)


class StreamEngine:
    def __init__(self, slim=PACK_SLIM, src=SRC, n_ctx=2048):
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
        self.tok_list = k["tokenizer.ggml.tokens"]
        self.tok_to_id = {t: i for i, t in enumerate(self.tok_list)}
        self.cos, self.sin = build_rope(self.hd, n_ctx, self.freq, np.float32)

        meta, by = read_packslim(slim)
        t0 = time.time()
        self.mat = {}
        for name, e in by.items():
            if e.get("bytes", 0) > 0:
                self.mat[name] = SlimMat(slim, e)
        # norm 权重 (fp32) + token_embd (Q8_0) 从源 GGUF 读
        self.norm = {}
        for t in self.infos:
            if t.type == 0:
                n = int(np.prod(t.dims))
                raw = M.tensor_slice(src, self.ds + t.offset, 0, n * 4)
                self.norm[t.name] = np.frombuffer(raw, np.float32).reshape(t.dims)
            elif t.name == "token_embd.weight":
                n_in, n_out = t.dims
                qk = M.BLOCK_ELEMS[M.GGML_TYPE_Q8_0]
                nb = int(n_in * n_out) // qk
                self.embd = M.dequant_blocks(src, t, self.ds, 0, nb).astype(
                    np.float32).reshape(n_in, n_out)
        print(f"[load] {len(self.mat)} Q1T 流式张量 + norm/embd  {time.time()-t0:.1f}s",
              file=sys.stderr)

    def encode(self, text):
        ids = []
        i = 0
        while i < len(text):
            hit = False
            for j in range(len(text), i, -1):
                if text[i:j] in self.tok_to_id:
                    ids.append(self.tok_to_id[text[i:j]]); i = j; hit = True; break
            if not hit:
                ids.append(self.tok_to_id.get(text[i], 0)); i += 1
        return ids

    def decode(self, ids):
        return "".join(self.tok_list[i] for i in ids)

    def forward(self, toks):
        T = len(toks)
        n_layer, n_embd, n_ff = self.n_layer, self.n_embd, self.n_ff
        nh, nkv, hd = self.n_head, self.n_kv, self.hd
        M = self.mat
        x = self.embd[:, toks].T.astype(np.float32)          # (T, embd)
        cos, sin = self.cos[:T], self.sin[:T]
        rep = nh // nkv
        for i in range(n_layer):
            p = f"blk.{i}."
            h = rmsnorm(x, self.norm[p + "attn_norm.weight"], self.eps)
            q = M[p + "attn_q.weight"].matmul(h).reshape(T, nh, hd)
            kk = M[p + "attn_k.weight"].matmul(h).reshape(T, nkv, hd)
            vv = M[p + "attn_v.weight"].matmul(h).reshape(T, nkv, hd)
            q = apply_rope(q, cos, sin, np.arange(T))
            kk = apply_rope(kk, cos, sin, np.arange(T))
            q = rmsnorm(q, self.norm[p + "attn_q_norm.weight"], self.eps)
            kk = rmsnorm(kk, self.norm[p + "attn_k_norm.weight"], self.eps)
            kk = np.repeat(kk, rep, axis=1)
            vv = np.repeat(vv, rep, axis=1)
            sc = np.einsum("qhd,khd->hqk", q, kk) / math.sqrt(hd)
            mask = np.triu(np.ones((T, T), bool), 1)[None]
            sc = np.where(mask, -1e9, sc)
            pr = np.exp(sc - sc.max(-1, keepdims=True))
            pr /= pr.sum(-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", pr, vv).reshape(T, nh * hd)
            o = M[p + "attn_output.weight"].matmul(o)
            x = x + o
            h = rmsnorm(x, self.norm[p + "ffn_norm.weight"], self.eps)
            g = M[p + "ffn_gate.weight"].matmul(h)
            u = M[p + "ffn_up.weight"].matmul(h)
            x = x + M[p + "ffn_down.weight"].matmul(g / (1 + np.exp(-g)) * u)
        x = rmsnorm(x, self.norm["output_norm.weight"], self.eps)
        return x @ self.embd   # (T,1024)@(1024,V)=(T,V)

    def generate(self, prompt, n_new=8, temperature=0.8, seed=0):
        rng = np.random.default_rng(seed)
        ids = list(self.encode(prompt))
        t0 = time.time()
        out = []
        for _ in range(n_new):
            lg = self.forward(np.array(ids, np.int64))[-1]
            lg = lg / temperature
            lg = lg - lg.max()
            p = np.exp(lg); p /= p.sum()
            out.append(int(rng.choice(len(self.tok_list), p=p)))
            ids.append(out[-1])
        return out, time.time() - t0


if __name__ == "__main__":
    eng = StreamEngine()
    sys.stderr.write(f"vocab {len(eng.tok_list)} layers {eng.n_layer}\n")
    ids = eng.encode("hi")
    lg = eng.forward(np.array(ids, np.int64))
    sys.stderr.write(f"logits {lg.shape} max {float(lg.max())}\n")
    top = np.argsort(lg[-1])[::-1][:8]
    print("top8:", [(eng.tok_list[i], round(float(lg[-1][i]), 2)) for i in top])