#!/data/data/com.termux/files/usr/bin/python3
"""ref_q8_engine.py — 非量化 Q8_0 numpy 参照引擎.
复用 StreamEngine 的 tokenizer/rope/norm/注意力, 仅权重用 Q8_0 精确反量化.
用途: 对照 QxT 退化是否来自量化 vs 引擎本身."""
import sys, os, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import q1t_stream as S
import mxfp4_regress as M


class RefEngine(S.StreamEngine):
    def __init__(self, src=S.SRC, n_ctx=2048):
        self.src = src
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
        self.cos, self.sin = S.build_rope(self.hd, n_ctx, self.freq, np.float32)
        te = next(t for t in self.infos if t.name == "token_embd.weight")
        ne, nv = int(te.dims[0]), int(te.dims[1])
        self.embd = M.dequant_blocks(src, te, self.ds, 0, (nv * ne) // 32).reshape(ne, nv).astype(np.float32)
        self.norm = {}
        with open(src, "rb") as f:
            for t in self.infos:
                if t.type == M.GGML_TYPE_F32 and len(t.dims) == 1:
                    f.seek(self.ds + t.offset)
                    self.norm[t.name] = np.frombuffer(f.read(int(t.dims[0]) * 4), np.float32).copy()
        self.W = {}
        qk = 32
        for t in self.infos:
            if t.type != M.GGML_TYPE_Q8_0 or len(t.dims) < 2:
                continue
            n_out, n_in = int(t.dims[1]), int(t.dims[0])
            nb = (n_in * n_out) // qk
            w = M.dequant_blocks(src, t, self.ds, 0, nb).astype(np.float32)
            self.W[t.name] = w.reshape(n_out, n_in).copy()   # (out, in), 块=列外循环
        self.bit = 8
        self._embd_raw = None
        print(f"[ref] 反量化 {len(self.W)} 张量", flush=True)

    # -------- 可复用的前向 (供蒸馏教师使用) --------
    def _lazy(self):
        """延迟构建 _merge_rank / bpe_cache (StreamEngine.encode 需要)."""
        if not hasattr(self, "_merge_rank"):
            self._merge_rank = {}
            for i, m in enumerate(getattr(self, "merges", [])):
                p = m.split(" ")
                if len(p) == 2:
                    self._merge_rank[(p[0], p[1])] = i
            self.bpe_cache = {}
            if not hasattr(self, "merges"):
                self.merges = self.kv.get("tokenizer.ggml.merges", [])

    def forward(self, ids, cache=None):
        """ids: list[int]. 返回 (logits (T,V) fp32, cache).

        cache=None 为全前向; 否则增量处理 ids[-1] (与 StreamEngine 语义一致,
        但本实现为纯 numpy fp32, 仅用于离线教师, 不追求速度).
        """
        import q1t_stream as S
        self._lazy()
        ids = list(ids)
        T = len(ids)
        nh, nkv, hd = self.n_head, self.n_kv, self.hd
        rep = nh // nkv
        M_ = self.W
        std = lambda x: x * (1.0 / np.sqrt(np.mean(x * x, -1, keepdims=True)
                                           + self.eps))
        fresh = cache is None
        if fresh:
            x = self.embd[:, ids].T.astype(np.float32)
            cache = {}
            T2, start = T, 0
        else:
            x = self.embd[:, ids[-1:]].T.astype(np.float32)
            T2, start = T, T - 1
        cos, sin = self.cos[:T2], self.sin[:T2]
        for i in range(self.n_layer):
            p = f"blk.{i}."
            h = std(x) * self.norm[p + "attn_norm.weight"]
            q = (h @ M_[p + "attn_q.weight"].T).reshape(-1, nh, hd)
            kk = (h @ M_[p + "attn_k.weight"].T).reshape(-1, nkv, hd)
            vv = (h @ M_[p + "attn_v.weight"].T).reshape(-1, nkv, hd)
            q = std(q) * self.norm[p + "attn_q_norm.weight"]
            kk = std(kk) * self.norm[p + "attn_k_norm.weight"]
            q = S.apply_rope(q, cos, sin, np.arange(T2 - start) + start)
            kk = S.apply_rope(kk, cos, sin, np.arange(T2 - start) + start)
            if fresh:
                ck, cv = kk, vv
            else:
                ck = np.concatenate((cache[i][0], kk), 0)
                cv = np.concatenate((cache[i][1], vv), 0)
            cache[i] = (ck, cv)
            sc = np.einsum("qhd,khd->hqk", q,
                           np.repeat(ck, rep, 1)) / np.sqrt(hd)
            if fresh:
                sc = np.where(np.triu(np.ones((T2, T2), bool), 1)[None],
                              -1e9, sc)
            pr = np.exp(sc - sc.max(-1, keepdims=True))
            pr /= pr.sum(-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", pr,
                          np.repeat(cv, rep, 1)).reshape(-1, nh * hd)
            x = x + o @ M_[p + "attn_output.weight"].T
            h = std(x) * self.norm[p + "ffn_norm.weight"]
            g = h @ M_[p + "ffn_gate.weight"].T
            u = h @ M_[p + "ffn_up.weight"].T
            x = x + (g * (1 / (1 + np.exp(-g))) * u) @ M_[p + "ffn_down.weight"].T
        x = std(x) * self.norm["output_norm.weight"]
        return x @ self.embd, cache


if __name__ == "__main__":
    # 用法: ref_q8_engine.py [n_new] [--src PATH] [--raw PROMPT]
    #   --src   指定源 gguf (默认 S.SRC)
    #   --raw   直接给裸 prompt (不加 chat template)
    args = sys.argv[1:]
    n_new, src, raw_prompt = 12, S.SRC, None
    i = 0
    while i < len(args):
        if args[i] == "--src":
            src = args[i + 1]; i += 2
        elif args[i] == "--raw":
            raw_prompt = args[i + 1]; i += 2
        else:
            n_new = int(args[i]); i += 1
    eng = RefEngine(src)
    if raw_prompt is not None:
        ids = list(eng.encode(raw_prompt))
    else:
        im_s, im_e = 151644, 151645
        ids = ([im_s] + list(eng.encode("You are Qwen3. You are a helpful assistant. /no_think"))
               + [im_e, im_s] + list(eng.encode("user\n1+1=?"))
               + [im_e, im_s] + list(eng.encode("assistant\n")))
    T = len(ids)
    n_layer, n_embd = eng.n_layer, eng.n_embd
    nh, nkv, hd = eng.n_head, eng.n_kv, eng.hd
    M_ = eng.W
    std = lambda x: x * (1.0 / np.sqrt((x * x).mean(-1, keepdims=True) + eng.eps))
    cos, sin = eng.cos[:T], eng.sin[:T]
    rep = nh // nkv
    cache = {}
    x = eng.embd[:, ids].T.astype(np.float32)
    for i in range(n_layer):
        p = f"blk.{i}."
        h = std(x) * eng.norm[p + "attn_norm.weight"]
        q = (h @ M_[p + "attn_q.weight"].T).reshape(-1, nh, hd)
        kk = (h @ M_[p + "attn_k.weight"].T).reshape(-1, nkv, hd)
        vv = (h @ M_[p + "attn_v.weight"].T).reshape(-1, nkv, hd)
        q = std(q) * eng.norm[p + "attn_q_norm.weight"]
        kk = std(kk) * eng.norm[p + "attn_k_norm.weight"]
        q = S.apply_rope(q, cos, sin, np.arange(T))
        kk = S.apply_rope(kk, cos, sin, np.arange(T))
        cache[i] = (kk, vv)
        sc = np.einsum("qhd,khd->hqk", q, np.repeat(kk, rep, 1)) / np.sqrt(hd)
        mask = np.triu(np.ones((T, T), bool), 1)[None]
        sc = np.where(mask, -1e9, sc)
        pr = np.exp(sc - sc.max(-1, keepdims=True)); pr /= pr.sum(-1, keepdims=True)
        o = np.einsum("hqk,khd->qhd", pr, np.repeat(vv, rep, 1)).reshape(-1, nh * hd)
        x = x + o @ M_[p + "attn_output.weight"].T
        h = std(x) * eng.norm[p + "ffn_norm.weight"]
        g = h @ M_[p + "ffn_gate.weight"].T
        u = h @ M_[p + "ffn_up.weight"].T
        x = x + (g * (1 / (1 + np.exp(-g))) * u) @ M_[p + "ffn_down.weight"].T
    x = std(x) * eng.norm["output_norm.weight"]
    lg = x @ eng.embd
    out = [int(np.argmax(lg[-1]))]
    for _ in range(n_new):
        # 增量: 单 token
        ids2 = ids + out
        T2 = len(ids2)
        x = eng.embd[:, ids2[-1:]].T.astype(np.float32)
        cos, sin = eng.cos[:T2], eng.sin[:T2]
        for i in range(n_layer):
            p = f"blk.{i}."
            h = std(x) * eng.norm[p + "attn_norm.weight"]
            q = (h @ M_[p + "attn_q.weight"].T).reshape(-1, nh, hd)
            kk = (h @ M_[p + "attn_k.weight"].T).reshape(-1, nkv, hd)
            vv = (h @ M_[p + "attn_v.weight"].T).reshape(-1, nkv, hd)
            q = std(q) * eng.norm[p + "attn_q_norm.weight"]
            kk = std(kk) * eng.norm[p + "attn_k_norm.weight"]
            q = S.apply_rope(q, cos, sin, np.array([T2 - 1]))
            kk = S.apply_rope(kk, cos, sin, np.array([T2 - 1]))
            ck, cv = cache[i]
            ck = np.concatenate((ck, kk), 0); cv = np.concatenate((cv, vv), 0)
            cache[i] = (ck, cv)
            sc = np.einsum("qhd,khd->hqk", q, np.repeat(ck, rep, 1)) / np.sqrt(hd)
            pr = np.exp(sc - sc.max(-1, keepdims=True)); pr /= pr.sum(-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", pr, np.repeat(cv, rep, 1)).reshape(-1, nh * hd)
            x = x + o @ M_[p + "attn_output.weight"].T
            h = std(x) * eng.norm[p + "ffn_norm.weight"]
            g = h @ M_[p + "ffn_gate.weight"].T
            u = h @ M_[p + "ffn_up.weight"].T
            x = x + (g * (1 / (1 + np.exp(-g))) * u) @ M_[p + "ffn_down.weight"].T
        x = std(x) * eng.norm["output_norm.weight"]
        lg = x @ eng.embd
        out.append(int(np.argmax(lg)))
    print("REF gen:", repr(eng.decode_text(out)))