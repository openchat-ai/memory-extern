"""hebb_write.py — 赫布写入 (HebbWrite) 库.

**方法名: 赫布写入 / hebb** (2026-10-21 定名).
  - **赫布写入 HebbWrite** = 本项目的方法: 把事实**注入已训练模型**的 FFN,
    外积写入 + 单点归一化 + 区分力选层 + 振幅预算
  - **赫布构造 HebbBuild** = 论文的方法: **整块替换** MLP, raw/whitened 读出
  勿混用 (文档 docs/HEB_EXPERIMENT.md 有对照表).

已验证配方 (docs/HEB_EXPERIMENT.md §9, §10.9):
  value 方向 = embd[target]
  ΔB_i += c · v ⊗ φ_i(key) / |φ_i(key)|²      # 单点归一化 (关键: 论文 raw 无此项)
  层集合: 选**key 区分力好**的层 (18-22); 层 24+ 写入即污染 (§10.9.7)
  振幅: c 与层数配平 (总振幅 c×层数 ≈ 20~100, §10.9.2)

用法:
  H = HebbWriter(slim, src)                 # 加载引擎
  H.write(key_prompt, "print", c=5.0)        # 写入一条事实 (全层)
  H.forward_rank(key_prompt, "print")        # 查 target 的 rank
  H.restore()                                # 撤销写入
"""
import os
import sys
import math
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine, SRC, rmsnorm, apply_rope

DEFAULT_SLIM = ("/data/data/com.termux/files/home/models/qxt/"
                "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")


class Fp32Mat:
    """纯 fp32 权重, 提供与 SlimMat 一致的 .matmul 接口."""
    __slots__ = ("W", "n_in", "n_out")

    def __init__(self, W):
        self.W = np.ascontiguousarray(W, dtype=np.float32)
        self.n_in, self.n_out = self.W.shape

    def matmul(self, x):
        return x @ self.W


class HebbWriter:
    """往 Q4T 的多层 ffn_down (B) 做外积写入 (赫布写入 hebb)."""

    def __init__(self, slim=DEFAULT_SLIM, src=SRC, n_ctx=2048):
        self.eng = StreamEngine(slim=slim, src=src, n_ctx=n_ctx)
        self.N = self.eng.n_layer
        self.d = self.eng.n_embd
        F = self.eng.mat[f"blk.0.ffn_down.weight"].n_in
        self.F = F
        self._B = None            # 原始 down 权重 (fp32), 惰性物化
        self._dirty = set()       # 已被写入的层

    # ---------- 权重物化 / 恢复 ----------

    def _materialize(self):
        if self._B is None:
            self._B = {}
            eye_F = np.eye(self.F, dtype=np.float32)
            for i in range(self.N):
                self._B[i] = self.eng.mat[f"blk.{i}.ffn_down.weight"]._matmul_np(eye_F)
        return self._B

    def _set_down(self, layer, W):
        self.eng.mat[f"blk.{layer}.ffn_down.weight"] = Fp32Mat(W)
        self._dirty.add(layer)

    def restore(self, layers=None):
        """把 down 恢复为原始 Q4T 权重. layers=None 恢复全部."""
        B = self._materialize()
        for i in (range(self.N) if layers is None else layers):
            self._set_down(i, B[i])

    # ---------- 前向 / phi ----------

    def capture_phi(self, toks):
        """跑一次全前向, 返回每层末位的 φ (ffn_down 的输入), shape (N, F)."""
        M = self.eng.mat
        x = self.eng._embed(list(toks))
        T = len(toks)
        nh, nkv, hd = self.eng.n_head, self.eng.n_kv, self.eng.hd
        rep = nh // nkv
        cos, sin = self.eng.cos[:T], self.eng.sin[:T]
        phis = np.empty((self.N, self.F), np.float64)
        for i in range(self.N):
            p = f"blk.{i}."
            h = rmsnorm(x, self.eng.norm[p + "attn_norm.weight"], self.eng.eps)
            q = M[p + "attn_q.weight"].matmul(h).reshape(-1, nh, hd)
            kk = M[p + "attn_k.weight"].matmul(h).reshape(-1, nkv, hd)
            vv = M[p + "attn_v.weight"].matmul(h).reshape(-1, nkv, hd)
            q = rmsnorm(q, self.eng.norm[p + "attn_q_norm.weight"], self.eng.eps)
            kk = rmsnorm(kk, self.eng.norm[p + "attn_k_norm.weight"], self.eng.eps)
            q = apply_rope(q, cos, sin, np.arange(T))
            kk = apply_rope(kk, cos, sin, np.arange(T))
            ckr = np.repeat(kk, rep, 1)
            cvr = np.repeat(vv, rep, 1)
            sc = np.einsum("qhd,khd->hqk", q, ckr) / math.sqrt(hd)
            mask = np.triu(np.ones((T, T), bool), 1)[None]
            sc = np.where(mask, -1e9, sc)
            pr = np.exp(sc - sc.max(-1, keepdims=True))
            pr /= pr.sum(-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", pr, cvr).reshape(-1, nh * hd)
            x = x + M[p + "attn_output.weight"].matmul(o)
            h = rmsnorm(x, self.eng.norm[p + "ffn_norm.weight"], self.eng.eps)
            g = M[p + "ffn_gate.weight"].matmul(h)
            u = M[p + "ffn_up.weight"].matmul(h)
            phi = g / (1 + np.exp(-g)) * u
            phis[i] = phi[-1]
            x = x + M[p + "ffn_down.weight"].matmul(phi)
        return phis

    def capture_vecs(self, toks):
        """跑一次全前向, 返回每层 (残差 res, FFN 激活 phi), 保留所有位置.
        res: (N, T, d), phi: (N, T, F). 用于检索区分力实验."""
        M = self.eng.mat
        x = self.eng._embed(list(toks))
        T = len(toks)
        nh, nkv, hd = self.eng.n_head, self.eng.n_kv, self.eng.hd
        rep = nh // nkv
        cos, sin = self.eng.cos[:T], self.eng.sin[:T]
        res = np.empty((self.N, T, self.d), np.float64)
        phis = np.empty((self.N, T, self.F), np.float64)
        mask = np.triu(np.ones((T, T), bool), 1)[None]
        for i in range(self.N):
            p = f"blk.{i}."
            h = rmsnorm(x, self.eng.norm[p + "attn_norm.weight"], self.eng.eps)
            q = M[p + "attn_q.weight"].matmul(h).reshape(-1, nh, hd)
            kk = M[p + "attn_k.weight"].matmul(h).reshape(-1, nkv, hd)
            vv = M[p + "attn_v.weight"].matmul(h).reshape(-1, nkv, hd)
            q = rmsnorm(q, self.eng.norm[p + "attn_q_norm.weight"], self.eng.eps)
            kk = rmsnorm(kk, self.eng.norm[p + "attn_k_norm.weight"], self.eng.eps)
            q = apply_rope(q, cos, sin, np.arange(T))
            kk = apply_rope(kk, cos, sin, np.arange(T))
            ckr = np.repeat(kk, rep, 1)
            cvr = np.repeat(vv, rep, 1)
            sc = np.einsum("qhd,khd->hqk", q, ckr) / math.sqrt(hd)
            sc = np.where(mask, -1e9, sc)
            pr = np.exp(sc - sc.max(-1, keepdims=True))
            pr /= pr.sum(-1, keepdims=True)
            o = np.einsum("hqk,khd->qhd", pr, cvr).reshape(-1, nh * hd)
            x = x + M[p + "attn_output.weight"].matmul(o)
            res[i] = x
            h = rmsnorm(x, self.eng.norm[p + "ffn_norm.weight"], self.eng.eps)
            g = M[p + "ffn_gate.weight"].matmul(h)
            u = M[p + "ffn_up.weight"].matmul(h)
            phi = g / (1 + np.exp(-g)) * u
            phis[i] = phi
            x = x + M[p + "ffn_down.weight"].matmul(phi)
        return res, phis

    def forward(self, toks):
        lo, _ = self.eng.forward(np.asarray(toks, np.int64))
        return lo

    def embed(self, token_id):
        return self.eng._embed([token_id])[0].astype(np.float64)

    def target_id(self, target):
        """把 target 解析为 token id.

        - int -> 直接用
        - 字符串 -> **优先**取 ' '+s 的版本 (词首/句中位置, 模型的默认情形),
          因为 Qwen3 byte-BPE 里词首 token 通常带前导空格 'Ġ' (§11.1)。
          若 ' '+s 编码出多 token 或不存在, 退回 s 本身。
        """
        if isinstance(target, (int, np.integer)):
            return int(target)
        ids_sp = self.eng.encode(" " + target) if target else []
        if len(ids_sp) == 1:
            return ids_sp[0]
        if target in self.eng.tok_to_id:
            return self.eng.tok_to_id[target]
        ids = self.eng.encode(target)
        if len(ids) == 1:
            return ids[0]
        return ids_sp[0] if ids_sp else ids[0]

    # ---------- 写入 ----------

    def write(self, key_prompt, target_token, c=5.0, layers=None):
        """写入一条事实: key_prompt 的末位 -> target_token.

        layers=None 表示全层. 返回 (rank, top1_token).
        """
        B = self._materialize()
        if layers is None:
            layers = list(range(self.N))
        toks = np.array(self.eng.encode(key_prompt), np.int64)
        phis = self.capture_phi(toks)
        tgt = self.target_id(target_token)
        v = self.embed(tgt)
        for i in layers:
            pk = phis[i]
            denom = pk @ pk
            if denom < 1e-9:
                continue
            dB = np.outer(pk, c * v) / denom
            self._set_down(i, B[i] + dB.astype(np.float32))
        lo = self.forward(toks)
        return int((lo > lo[tgt]).sum()), self.eng.tok_list[int(lo.argmax())]

    def write_random(self, key_prompt, c=5.0, layers=None, seed=0):
        """对照: 用随机 val 方向写入 (应无效)."""
        B = self._materialize()
        if layers is None:
            layers = list(range(self.N))
        toks = np.array(self.eng.encode(key_prompt), np.int64)
        phis = self.capture_phi(toks)
        rng = np.random.default_rng(seed)
        v = rng.standard_normal(self.d)
        for i in layers:
            pk = phis[i]
            denom = pk @ pk
            if denom < 1e-9:
                continue
            dB = np.outer(pk, c * v) / denom
            self._set_down(i, B[i] + dB.astype(np.float32))

    # ---------- 查询 ----------

    def rank_of(self, key_prompt, target_token):
        toks = np.array(self.eng.encode(key_prompt), np.int64)
        tgt = self.target_id(target_token)
        lo = self.forward(toks)
        return int((lo > lo[tgt]).sum()), self.eng.tok_list[int(lo.argmax())]

    def gen_text(self, prompt, n_new=12, temperature=0.01):
        ids, _ = self.eng.generate(prompt, n_new=n_new, temperature=temperature)
        return self.eng.decode_text(ids)


if __name__ == "__main__":
    # 自检: 重跑已验证的单条事实, 结果应与 qxt_heb_accept2.py 一致
    H = HebbWriter()
    p = "def add(a, b):"
    print("[基线]", H.rank_of(p, "print"))
    print("[基线生成]", repr(H.gen_text(p, 12)))
    r, top1 = H.write(p, "print", c=5.0)
    print(f"[写入] rank={r} top1={top1!r}")
    print("[写入生成]", repr(H.gen_text(p, 12)))
    H.restore()
    print("[恢复后]", H.rank_of(p, "print"))


# 兼容别名: 旧脚本用 HebbInjector
HebbInjector = HebbWriter
