#!/data/data/com.termux/files/usr/bin/python3
"""bpe_tokenizer.py — Qwen2/GPT2 BPE (从 GGUF tokens/merges 重建)。

decode: 拼接 tokens, Ġ -> 空格, ▁ 兼容.
encode: qwen2 pre (空白->Ġ), 字符级初始切分, rank-based 合并, longest-match
        merges 外层贪心 (严格 GPT2 顺序).
"""
import os, sys, re
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mxfp4_regress as M

# GPT2/Qwen2 预分词正则 (ASCII 简化版), 必须跑在原文上
_PRETOK = re.compile(
    r"'s|'t|'re|'ve|'m|'ll|'d| ?[A-Za-z0-9]+| ?[^\sA-Za-z0-9]+|\s+")


class BpeTokenizer:
    def __init__(self, gguf_path):
        kv, _, _ = M.read_gguf(gguf_path)
        self.tokens = list(kv["tokenizer.ggml.tokens"])
        self.merges = list(kv["tokenizer.ggml.merges"])
        self.tok_to_id = {t: i for i, t in enumerate(self.tokens)}
        eos = kv["tokenizer.ggml.eos_token_id"]
        self.eos = int(eos)
        # 反向合并表: pair(tuple) -> rank
        self.rank = {}
        for r, m in enumerate(self.merges):
            a, b = m.split()
            self.rank[(a, b)] = r
        # 特殊 token ids
        self.special_ids = set()
        if "tokenizer.ggml.token_type" in kv and "tokenizer.ggml.special_tokens" in kv:
            st = kv["tokenizer.ggml.special_tokens"]
            # special 通常是 tokens 中 type==3 的尾部
            for i, t in enumerate(self.tokens):
                if t.startswith("<|im_") or t.startswith("<|endoftext|>"):
                    self.special_ids.add(i)
        # byte 词元 (仅用于无法 fallback 时)
        self.byte_toks = {"<0x%02X>" % i: i for i in range(256)}

    def _pre(self, text):
        # 字节级映射 (GPT2 byte-level BPE). 注意: 不能把 \s+ 压成 Ġ ——
        # 换行必须是 Ċ, 否则 chat template 的换行结构全部丢失.
        s = text.replace(" ", "Ġ").replace("\n", "Ċ").replace("\t", "ĉ")
        return s

    def _word_chars(self, word):
        return list(word)

    def encode(self, text):
        if not text:
            return []
        # 预分词正则跑在**原文**上 (空格/换行尚未替换), 再逐 piece 做字节映射.
        # 若先把空格换成 Ġ 再切, 'ĠFrance' 会被拆成 'Ġ'+'France'.
        ids = []
        for raw in _PRETOK.findall(text):
            piece = raw.replace(" ", "Ġ").replace("\n", "Ċ").replace("\t", "ĉ")
            for tk in self._encode_piece(piece):
                ids.append(self.tok_to_id[tk] if tk in self.tok_to_id else 0)
        return ids

    def _encode_piece(self, piece):
        # 词符初始 = 每个字符 (含 Ġ 已并入)
        syms = [c for c in piece]
        while True:
            best_pair, best_rank = None, 1 << 30
            for i in range(len(syms) - 1):
                p = (syms[i], syms[i + 1])
                r = self.rank.get(p)
                if r is not None and r < best_rank:
                    best_rank, best_pair = r, p
            if best_pair is None:
                break
            i = 0
            new = []
            while i < len(syms):
                if i + 1 < len(syms) and (syms[i], syms[i + 1]) == best_pair:
                    new.append(syms[i] + syms[i + 1]); i += 2
                else:
                    new.append(syms[i]); i += 1
            syms = new
        return syms

    def decode(self, ids):
        out = []
        for i in ids:
            t = self.tokens[i]
            out.append(t.replace("Ġ", " ").replace("Ċ", "\n")
                       .replace("ĉ", "\t").replace("▁", " ")
                       if not t.startswith("<0x") else chr(int(t[4:6], 16)))
        return "".join(out)


if __name__ == "__main__":
    b = BpeTokenizer("/data/data/com.termux/files/home/models/rStar-Coder-Qwen3-0.6B.Q8_0.gguf")
    for s in ("hi", "Hello! How can I assist you today?", "一加一等于几?"):
        ids = b.encode(s)
        print(repr(s), "->", ids)
        print("   decode:", repr(b.decode(ids)))