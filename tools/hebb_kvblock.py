"""赫布静态事实块 (hebb-kvblock): 把事实的 K/V 以常量前缀烘进模型.

零训练. 事实不进入文本, 也不改任何权重:
  1. 在干净上下文里跑一遍事实块, 采集每层 K/V (28 层 x 2 x L x nkv x hd)
  2. 保存为 .kvblk (npz + json)
  3. 推理时用占位 token 撑出 L 个位置, 把 K/V 强制覆写进去
     -> 模型看到的前缀与"事实真的在上下文里"逐位相同 (见 docs §10.14)

用法:
  python tools/hebb_kvblock.py --build facts.txt --out /tmp/wc.kvblk
  python tools/hebb_kvblock.py --load /tmp/wc.kvblk --ask "What is the capital city of that country?"
"""
import argparse
import json
import sys

import numpy as np

sys.path.insert(0, "/data/data/com.termux/files/home/sram/tools")
from q1t_stream import StreamEngine  # noqa: E402
from hebb_write import DEFAULT_SLIM  # noqa: E402


def _engine():
    """必须显式指定 Q4T 包: StreamEngine() 默认是 Q1T (1-bit), 结果不具可比性."""
    return StreamEngine(slim=DEFAULT_SLIM, n_ctx=2048)


class KvBlock:
    """一组事实的常量 K/V 前缀."""

    def __init__(self, n_slots, kv, lines=None, path=None):
        self.n_slots = int(n_slots)
        self.kv = kv                      # {layer: (K, V)}  (L,nkv,hd)
        self.lines = lines or []
        self.path = path

    @classmethod
    def build(cls, lines, out=None, engine=None):
        E = engine or _engine()
        text = "\n".join(s.rstrip("\n") for s in lines) + "\n"
        ids = E.encode(text)
        _, cap = E.forward(np.array(ids, np.int64), capture_kv=True)
        kv = {i: (cap[i][0], cap[i][1]) for i in range(E.n_layer)}
        blk = cls(len(ids), kv, lines=lines)
        if out:
            blk.save(out)
        return blk

    def save(self, path):
        meta = {"n_slots": self.n_slots, "lines": self.lines, "n_layer": len(self.kv)}
        arr = {}
        for i, (k, v) in self.kv.items():
            arr[f"k{i}"] = k.astype(np.float32)
            arr[f"v{i}"] = v.astype(np.float32)
        arr["meta"] = np.frombuffer(json.dumps(meta).encode(), np.uint8)
        with open(path, "wb") as f:
            np.savez_compressed(f, **arr)
        self.path = path
        return path

    @classmethod
    def load(cls, path):
        z = np.load(path, allow_pickle=False)
        meta = json.loads(bytes(z["meta"]).decode())
        kv = {i: (z[f"k{i}"], z[f"v{i}"]) for i in range(meta["n_layer"])}
        return cls(meta["n_slots"], kv, lines=meta.get("lines"), path=path)

    def force(self, engine, off=0):
        """forward(force_kv=...) 用的字典; off = 块在上下文中的起始位置.
        块本身从位置 0 采集, off>0 时按新位置重施 RoPE (会挤占位置, 实测变差)."""
        f = {}
        for i, (k, v) in self.kv.items():
            kk = k
            if off:
                from q1t_stream import apply_rope  # noqa
                kk = apply_rope(k, engine.cos, engine.sin,
                                np.arange(off, off + len(k)))
            f[i] = (slice(off, off + len(k)), kk, v)
        return f

    def answer(self, engine, question, n_new=16):
        pad = engine.encode("\n")[0]
        ids = [pad] * self.n_slots + engine.encode(question)
        lg, cache = engine.forward(np.array(ids, np.int64), force_kv=self.force(engine))
        out = []
        for _ in range(n_new):
            t = int(np.argmax(lg))
            out.append(t)
            ids.append(t)
            lg, cache = engine.forward(np.array(ids, np.int64), cache)
        return engine.decode_text(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build")
    ap.add_argument("--out")
    ap.add_argument("--load")
    ap.add_argument("--ask")
    a = ap.parse_args()
    if a.build:
        lines = [ln for ln in open(a.build, encoding="utf-8").read().splitlines() if ln.strip()]
        blk = KvBlock.build(lines, out=a.out)
        print(f"[build] {len(lines)} facts -> {blk.n_slots} slots -> {a.out}")
        return
    if a.load:
        blk = KvBlock.load(a.load)
        E = _engine()
        print(f"[load] {blk.n_slots} slots, {len(blk.kv)} layers")
        for q in (a.ask or []).split("|"):
            print(f"  Q: {q.strip()}\n  A: {blk.answer(E, q.strip())!r}")


if __name__ == "__main__":
    main()
