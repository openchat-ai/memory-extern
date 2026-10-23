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
import re
import numpy as np
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M
import qxt_fidelity_scan as Q

MAGIC = b"QXTSLIM1\n"

# GPT2/Qwen2 预分词正则 (ASCII 简化版). 必须跑在**原文**上, 再对每个 piece
# 做字节级映射 (' '->Ġ, '\n'->Ċ) —— 若先把空格换成 Ġ 再切, 'ĠFrance' 会被
# 拆成 'Ġ'+'France', 偏离训练分布.
_PRETOK = re.compile(
    r"'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-z0-9]+| ?[^\sA-Za-z0-9]+|\s+")

PACK_SLIM = ("/data/data/com.termux/files/home/models/qxt/"
             "rStar-Coder-Qwen3-0.6B.Q8_0-Q1T_packslim.gguf")
MODEL_DIR = "/data/data/com.termux/files/home/models"
SRC = os.path.join(MODEL_DIR, "rStar-Coder-Qwen3-0.6B.Q8_0.gguf")

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


# --- C 位操作 GEMM 后端 (T-MAC 式, 仅加/减) ---
import ctypes as _ct
_LIB = None
def _load_lib():
    global _LIB
    if _LIB is None:
        p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "q1t_gemm.so")
        try:
            lib = _ct.CDLL(p)
            lib.q1t_gemm.argtypes = [_ct.c_void_p, _ct.c_int, _ct.c_int,
                                     _ct.c_void_p, _ct.c_int, _ct.c_void_p]
            lib.q1t_gemm_t.argtypes = [_ct.c_void_p, _ct.c_int, _ct.c_int,
                                       _ct.c_void_p, _ct.c_int, _ct.c_void_p, _ct.c_int]
            lib.q8_gemm_proj.argtypes = [_ct.c_void_p, _ct.c_int, _ct.c_int,
                                         _ct.c_void_p, _ct.c_int, _ct.c_void_p, _ct.c_int]
            lib.qxt_gemm_t.argtypes = [_ct.c_void_p, _ct.c_int, _ct.c_int,
                                       _ct.c_void_p, _ct.c_int, _ct.c_void_p,
                                       _ct.c_void_p, _ct.c_int, _ct.c_int]
            lib.q1t_gemm.restype = None
            lib.q1t_gemm_t.restype = None
            lib.q8_gemm_proj.restype = None
            lib.qxt_gemm_t.restype = None
            _LIB = lib
        except OSError:
            _LIB = False
    return _LIB

def q8_gemm_proj(w, n_in, n_out, x, T, y, nt):
    _load_lib().q8_gemm_proj(w, n_in, n_out, x, T, y, nt)


def _nthreads():
    """GEMM 线程数: 默认 2, 可用 QXT_NT 环境变量覆盖 (实测 8 核下线程数影响很大)."""
    v = os.environ.get("QXT_NT")
    return int(v) if v else 2


class SlimMat:
    """Bare-hosted streaming GEMM: y = x @ W, W 以 (scale+bits) 块流式读取.

    块布局: (n_in, n_out), 32 元素/块, 文件序 = 列主序 (块 b = j*ibp + ib).
    优先走 C 位操作内核, 无 .so 时退回 numpy。

    混合精度支持: entry 带 "bit" 字段时该张量用自己的 bitwidth 与码本
    (cb_by_bit), 缺省回落到全局 bit/cb。
    """

    def __init__(self, path, entry, bit=1, cb=None, cb_by_bit=None):
        self.path = path
        self.n_in, self.n_out = entry["dims"]
        self.off = entry["offset"]
        self.nb = (self.n_in * self.n_out) // QK
        # 混合精度: 张量自带 bit 优先
        self.bit = int(entry.get("bit", bit))
        self.cb_by_bit = cb_by_bit
        if self.cb_by_bit is not None and self.bit in self.cb_by_bit:
            cb = np.asarray(self.cb_by_bit[self.bit], np.float32)
        self.tot = self.nb * (1 + 4 * self.bit)
        self.dtype = np.float32
        self.cb = cb                         # (2^bit,) float32 码本值
        self._raw = None
        self.use_c = True

    def _load_raw(self):
        if self._raw is None:
            with open(self.path, "rb") as f:
                f.seek(self.off)
                self._raw = np.frombuffer(f.read(self.tot), np.uint8).copy()
        return self._raw

    def matmul(self, x):
        """x (T, n_in) -> (T, n_out). (fp32 输入, 块贡献=scale*±0.34188*Σ(±x_in))"""
        x = np.ascontiguousarray(x, np.float32)
        T = x.shape[0]
        n_in, n_out = self.n_in, self.n_out
        lib = _load_lib()
        if lib and self.use_c:
            w = self._load_raw()
            y = np.zeros((T, n_out), np.float32)
            if self.bit == 1:
                lib.q1t_gemm_t(w.ctypes.data, n_in, n_out, x.ctypes.data, T, y.ctypes.data, _nthreads())
            else:
                cb = self.cb.ctypes.data if self.cb is not None else 0
                lib.qxt_gemm_t(w.ctypes.data, n_in, n_out, x.ctypes.data, T,
                               y.ctypes.data, cb, self.bit, _nthreads())
            return y
        return self._matmul_np(x)

    def _matmul_np(self, x):
        """numpy 兜底: 反量化列主序权重 + 矩阵乘。
        块格式 {u8 sc; bits[4b]}, 块字节 1+4b, 每元素 b-bit LSB-first,
        块序 j*ibp+ib (列主序, ib = 输入块号)。"""
        n_in, n_out = self.n_in, self.n_out
        b = self.bit
        bb = 1 + 4 * b
        ibp = n_in // QK
        cb = self.cb if self.cb is not None else CB
        W = np.empty((n_in, n_out), np.float32)
        with open(self.path, "rb") as f:
            f.seek(self.off)
            for j0 in range(0, n_out, 64):
                nbc = min(64, n_out - j0)
                raw = f.read(nbc * ibp * bb)
                buf = np.frombuffer(raw, np.uint8).reshape(-1, bb)
                d = SC_TAB[buf[:, 0].astype(np.int64)]
                bits = np.unpackbits(np.ascontiguousarray(buf[:, 1:]),
                                     axis=1, bitorder="little")[:, :32 * b]
                code = np.zeros((len(buf), QK), np.int64)
                for k in range(b):
                    code |= bits[:, np.arange(QK) * b + k].astype(np.int64) << k
                val = d[:, None] * cb[code]
                W[:, j0:j0 + nbc] = val.reshape(nbc, n_in).T
        return x @ W


def rmsnorm(x, w, eps):
    return x * (1.0 / np.sqrt(np.mean(x * x, axis=-1, keepdims=True) + eps)) * w


def build_rope(head_dim, n_ctx, freq_base, dtype=np.float32):
    inv = 1.0 / (freq_base ** (np.arange(0, head_dim, 2, dtype=np.float32) / head_dim))
    ang = np.arange(n_ctx, dtype=np.float32)[:, None] * inv[None, :]
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


class StreamEngine:
    def __init__(self, slim=PACK_SLIM, src=None, n_ctx=2048):
        # 源 gguf 必须与 slim 包自洽: meta.src 记录了打包时的源文件名.
        # 若调用方传的 src 与之不符 (例如换用 1.7B 的包但沿用默认 0.6B 源),
        # 会读到错位维度的 norm/embd -> C 内核越界 segfault. 这里自动纠正.
        if src is None:
            src = SRC
            try:
                meta0, _ = read_packslim(slim)
                want = meta0.get("src")
                if want:
                    # meta["src"] 是打包时剥掉后缀的文件名
                    if not want.endswith(".gguf"):
                        want = want + ".gguf"
                    cands = [os.path.join(os.path.dirname(src), want),
                             os.path.join(os.path.dirname(SRC), want),
                             os.path.join(MODEL_DIR, want)]
                    for c in cands:
                        if os.path.exists(c):
                            src = c
                            break
            except Exception:
                pass
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
        self.merges = k.get("tokenizer.ggml.merges", [])
        # GGUF merges 形如 "W h" / "Ġ t" (空格分隔的对) -> 必须拆成 (a,b) 元组,
        # 直接用 a+b 拼接匹配永远命中不了, 会退化成逐字符编码.
        self._merge_rank = {}
        for i, m in enumerate(self.merges):
            parts = m.split(" ")
            if len(parts) == 2:
                self._merge_rank[(parts[0], parts[1])] = i
        self.bpe_cache = {}
        self.cos, self.sin = build_rope(self.hd, n_ctx, self.freq, np.float32)

        meta, by = read_packslim(slim)
        t0 = time.time()
        self.bit = int(meta.get("bitwidth", 1))
        if "codebook" in meta:
            self.cb = np.array(meta["codebook"], np.float32)
        else:
            # 旧 Q1T 文件无码本字段: 1-bit 用 ±CB
            self.cb = CB if self.bit == 1 else None
        # 混合精度: meta.codebooks = {bit_str: [码本]}, 按张量 bit 取对应码本
        self.cb_by_bit = None
        cbs = meta.get("codebooks")
        if cbs:
            self.cb_by_bit = {int(k): np.asarray(v, np.float32)
                              for k, v in cbs.items()}
        self.mat = {}
        for name, e in by.items():
            if e.get("bytes", 0) > 0:
                self.mat[name] = SlimMat(slim, e, self.bit, self.cb,
                                         self.cb_by_bit)
        # norm 权重 (fp32) + token_embd (Q8_0) 从源 GGUF 读
        self.norm = {}
        self._embd_raw = None
        self._embd_info = None            # (t, qk, nb) 惰性取词向量的信息
        for t in self.infos:
            if t.type == 0:
                n = int(np.prod(t.dims))
                raw = M.tensor_slice(src, self.ds + t.offset, 0, n * 4)
                self.norm[t.name] = np.frombuffer(raw, np.float32).reshape(t.dims)
            elif t.name == "token_embd.weight":
                n_in, n_out = t.dims
                qk = M.BLOCK_ELEMS[M.GGML_TYPE_Q8_0]
                nb = int(n_in * n_out) // qk
                # token_embd 在大模型上 fp32 达 1.2GB, 与 Q8 字节副本同时常驻会 OOM.
                # 只保留 Q8 原始字节 (供末投影 C 内核), 词向量按 token 惰性切片.
                with open(src, "rb") as f:
                    f.seek(self.ds + t.offset)
                    self._embd_raw = np.frombuffer(
                        f.read(nb * 34), np.uint8).copy()
                self._embd_info = (t, qk, n_in, n_out)
                self.n_vocab = n_out
        print(f"[load] {len(self.mat)} Q1T 流式张量 + norm/embd  {time.time()-t0:.1f}s",
              file=sys.stderr)
        self._pool = ThreadPoolExecutor(max_workers=4)

    def _embed(self, ids):
        """按 token 取词向量 (T, n_embd) —— 不持有完整 fp32 token_embd."""
        t, qk, n_in, n_out = self._embd_info
        ibp = n_in // qk
        out = np.empty((len(ids), n_in), np.float32)
        for k, tok in enumerate(ids):
            b0 = int(tok) * ibp                       # 该 token 的块区间
            nb = ibp
            wb = M.dequant_blocks(self.src, t, self.ds, b0, nb)
            out[k] = wb.reshape(n_in).astype(np.float32)
        return out

    def encode(self, text):
        # GPT2/Qwen2 BPE (严格 GPT2 顺序):
        #   1) 预分词正则跑在**原文**上 (空格/换行尚未替换)
        #   2) 每个 piece 内部做字节级映射 ' '->Ġ, '\n'->Ċ, '\t'->ĉ
        #   3) 字符级初始切分, 按 merge rank 最小者贪心合并
        if text == "":
            return []
        mrg = getattr(self, "_merge_rank", None)
        if mrg is None:
            mrg = {}
            for i, m in enumerate(getattr(self, "merges", [])):
                parts = m.split(" ")
                if len(parts) == 2:
                    mrg[(parts[0], parts[1])] = i
            self._merge_rank = mrg
        if not getattr(self, "bpe_cache", None):
            self.bpe_cache = {}
        cache = self.bpe_cache
        t2i = self.tok_to_id
        ids = []
        for piece in _PRETOK.findall(text):
            piece = piece.replace(" ", "Ġ").replace("\n", "Ċ").replace("\t", "ĉ")
            syms = cache.get(piece)
            if syms is None:
                syms = self._bpe(piece, mrg, t2i)
                cache[piece] = syms
            ids += syms
        self.bpe_cache = cache
        return ids

    def _bpe(self, piece, mrg, t2i):
        """对单个 piece 做 BPE.

        Qwen2 用完整 byte-level BPE: 词表**没有** <0xXX> 字节 token, 但有
        5837 条以 UTF-8 字节字面量 (如 'âĢĻ') 开头的 merge. 因此非 ASCII
        字符必须先拆成 GPT2 byte-encoder 的等价字符序列再合并, 否则
        '—' 这类符号会因不在词表而失败.
        """
        bytemap = getattr(self, "_byte_enc", None)
        if bytemap is None:
            bs = list(range(ord("!"), ord("~") + 1)) \
                + list(range(ord("\xa1"), ord("\xac") + 1)) \
                + list(range(ord("\xae"), ord("\xff") + 1))
            cs = bs[:]
            n = 0
            for b in range(256):
                if b not in bs:
                    bs.append(b)
                    cs.append(256 + n)
                    n += 1
            bytemap = {chr(b): chr(c) for b, c in zip(bs, cs)}
            self._byte_enc = bytemap

        def merge(seq):
            seq = list(seq)
            while True:
                cand = [(mrg[(seq[i], seq[i + 1])], i)
                        for i in range(len(seq) - 1)
                        if (seq[i], seq[i + 1]) in mrg]
                if not cand:
                    return seq
                _, bi = min(cand)
                seq[bi:bi + 2] = [seq[bi] + seq[bi + 1]]
            return seq

        out = []
        for ch in piece:
            if ch in t2i:
                out.append(ch)
            else:
                # 未登录字符 -> UTF-8 字节序列 (GPT2 byte-level BPE)
                try:
                    out += [bytemap[b] for b in ch.encode("utf-8")]
                except KeyError:
                    continue
        # 关键: 必须对**整个 piece** 一起 merge. 逐字符 merge 会把 'You' 拆成
        # 'Y'+'o'+'u' 三个 token (正确是一个 'You'), 分词全错.
        syms = merge(out)
        return [t2i[s] for s in syms if s in t2i]

    def decode(self, ids):
        return "".join(self.tok_list[i] for i in ids)

    def decode_text(self, ids):
        """decode + 字节级还原 (Ġ->空格, Ċ->换行)."""
        return (self.decode(ids).replace("Ġ", " ").replace("Ċ", "\n")
                .replace("ĉ", "\t"))

    def forward(self, toks, cache=None, full_logits=False, return_hidden=False,
                force_kv=None, capture_kv=False):
        """toks (T,). cache: {layer: (k, v)} 已缓存前缀 K/V (含 RoPE/QK-norm).
        full_logits=True 时返回 (T,V) 全部位置的 logits (蒸馏教师用).
        cache 为 None => 全前向; 否则增量最后 token.
        返回 (logits_last (V,), cache)."""
        T = len(toks)
        incremental = cache is not None
        n_layer, n_embd = self.n_layer, self.n_embd
        nh, nkv, hd = self.n_head, self.n_kv, self.hd
        M = self.mat
        if incremental:
            x = self._embed([toks[-1]])
            start = T - 1
        else:
            x = self._embed(list(toks))
            start = 0
        cos, sin = self.cos[:T], self.sin[:T]
        rep = nh // nkv
        if cache is None:
            cache = {}
        cap = {} if capture_kv else None
        for i in range(n_layer):
            p = f"blk.{i}."
            h = rmsnorm(x, self.norm[p + "attn_norm.weight"], self.eps)
            q = M[p + "attn_q.weight"].matmul(h).reshape(-1, nh, hd)
            kk = M[p + "attn_k.weight"].matmul(h).reshape(-1, nkv, hd)
            vv = M[p + "attn_v.weight"].matmul(h).reshape(-1, nkv, hd)
            q = rmsnorm(q, self.norm[p + "attn_q_norm.weight"], self.eps)
            kk = rmsnorm(kk, self.norm[p + "attn_k_norm.weight"], self.eps)
            q = apply_rope(q, cos, sin, np.arange(T - start) + start)
            kpre = kk
            kk = apply_rope(kk, cos, sin, np.arange(T - start) + start)
            if capture_kv:
                cap[i] = (kk.copy(), vv.copy(), kpre.copy())
            if force_kv and i in force_kv:
                pl, fk, fv = force_kv[i]
                kk[pl] = fk
                vv[pl] = fv
            if incremental:
                ck = np.concatenate((cache[i][0], kk), 0)   # (T, nkv, hd)
                cv = np.concatenate((cache[i][1], vv), 0)
            else:
                ck, cv = kk, vv
            cache[i] = (ck, cv)
            ckr = np.repeat(ck, rep, axis=1)                # (T, nh, hd)
            cvr = np.repeat(cv, rep, axis=1)
            sc = np.einsum("qhd,khd->hqk", q, ckr) / math.sqrt(hd)
            if incremental:
                pr = np.exp(sc - sc.max(-1, keepdims=True))
                pr /= pr.sum(-1, keepdims=True)
            else:
                mask = np.triu(np.ones((T, T), bool), 1)[None]
                sc = np.where(mask, -1e9, sc)
                pr = np.exp(sc - sc.max(-1, keepdims=True))
                pr /= pr.sum(-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", pr, cvr).reshape(-1, nh * hd)
            o = M[p + "attn_output.weight"].matmul(o)
            x = x + o
            h = rmsnorm(x, self.norm[p + "ffn_norm.weight"], self.eps)
            g = M[p + "ffn_gate.weight"].matmul(h)
            u = M[p + "ffn_up.weight"].matmul(h)
            x = x + M[p + "ffn_down.weight"].matmul(g / (1 + np.exp(-g)) * u)
        x = rmsnorm(x, self.norm["output_norm.weight"], self.eps)
        # 末投影: 走 Q8_0 C 内核 (读源 GGUF 原始字节, 省 467MB fp32 缓存)
        if self._embd_raw is not None:
            T = x.shape[0]
            lg = np.empty((T, self.n_vocab), np.float32)
            q8_gemm_proj(self._embd_raw.ctypes.data, self.n_embd,
                         self.n_vocab, x.ctypes.data, T, lg.ctypes.data, 2)
        else:
            lg = x @ self.embd   # (1,V) 或 (T,V)
        # full_logits=True 时返回全部位置 (T,V), 供蒸馏教师提取软目标
        # return_hidden=True 时额外返回末层隐状态 (T,d), 供候选重排打分器使用
        if return_hidden:
            r = ((lg if full_logits else lg[-1]), cache, x)
        else:
            r = ((lg if full_logits else lg[-1]), cache)
        return (r, cap) if capture_kv else r

    def generate(self, prompt, n_new=8, temperature=0.8, seed=0):
        rng = np.random.default_rng(seed)
        ids = list(self.encode(prompt))
        t0 = time.time()
        lg, cache = self.forward(np.array(ids, np.int64))
        out = []
        for _ in range(n_new):
            lg = lg / temperature
            lg = lg - lg.max()
            p = np.exp(lg); p /= p.sum()
            out.append(int(rng.choice(len(self.tok_list), p=p)))
            ids.append(out[-1])
            lg, cache = self.forward(np.array(ids, np.int64), cache)
        return out, time.time() - t0


if __name__ == "__main__":
    eng = StreamEngine()
    sys.stderr.write(f"vocab {len(eng.tok_list)} layers {eng.n_layer}\n")
    ids = eng.encode("hi")
    lg = eng.forward(np.array(ids, np.int64))
    sys.stderr.write(f"logits {lg.shape} max {float(lg.max())}\n")
    top = np.argsort(lg[-1])[::-1][:8]
    print("top8:", [(eng.tok_list[i], round(float(lg[-1][i]), 2)) for i in top])
