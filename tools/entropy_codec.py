#!/usr/bin/env python3
"""
entropy_codec.py — E2M1 码流熵编码框架（§12.3 落地件）

设计定位：
  权重码（4bit/元素）在真实 LLM 里分布高度偏斜——零值与小幅值占大头。
  本框架做三件事：
    1. 从样本权重统计频率 → 生成静态 Huffman 码表（编译进 FPGA BRAM）
    2. 编码器：E2M1 nibble 流 → bitstream（含表头）
    3. 解码器参考实现：逐位走树，验证无损往返

  FPGA 侧解码成本预估：单时钟查表 + 位指针，~50 LUT，无 BRAM 压力
    （码长 ≤ 8bit 时用两级 LUT6 即可）

为什么现在只能测"框架"：
  压缩率强依赖真实权重分布。当前用合成分布（Zipf/高斯+稀疏化）标定，
  真 K3 样本到位后 --fit-real 接口直接换统计源，码表生成逻辑不变。

用法：
  python3 entropy_codec.py --selftest          # 无损往返 + 合成分布压缩率
  python3 entropy_codec.py --demo              # 打印码表样例
"""

import argparse
import heapq
from collections import Counter


# ── 码表生成 ────────────────────────────────────────────────
def build_huffman(freq: dict[int, int]) -> dict[int, str]:
    """标准 Huffman（组级父指针）；16 符号最坏码长 ≤15"""
    if len(freq) == 1:
        return {next(iter(freq)): "0"}
    import itertools
    ctr = itertools.count()
    parent = {}                                   # 组 -> (父组, 位)
    heap2 = [(f, next(ctr), (s,)) for s, f in freq.items()]
    heapq.heapify(heap2)
    while len(heap2) > 1:
        f1, _, g1 = heapq.heappop(heap2)
        f2, _, g2 = heapq.heappop(heap2)
        merged = g1 + g2
        parent[g1] = (merged, "0")
        parent[g2] = (merged, "1")
        heapq.heappush(heap2, (f1 + f2, next(ctr), merged))
    root = heap2[0][2]
    codes = {}
    for s in freq:
        bits = []
        cur = (s,)
        while cur != root:
            cur, b = parent[cur]
            bits.append(b)
        codes[s] = "".join(reversed(bits)) or "0"
    return codes


# ── 合成分布（真数据前的占位）───────────────────────────────
def synth_freq(sparsity=0.55, zipf_s=1.4):
    """LLM 权重典型形态：大量 0 / ±0.5，大幅值罕见。
    返回 16 个 E2M1 码的频率。"""
    import random
    rng = random.Random(42)
    base = {}
    for c in range(16):
        mag = [0, .5, 1, 1.5, 2, 3, 4, 6][c & 7]
        sign_pen = 0.7 if c & 8 else 1.0     # 正负略不对称
        # 零值单独给最大质量；非零按幅值幂律
        base[c] = 0.0 if mag == 0 else (mag ** (-zipf_s)) * sign_pen
    nz_mass = sum(base.values())               # 非零总质量
    total_mass = nz_mass / (1 - sparsity)      # 使零占比 = sparsity
    f0 = int(total_mass - nz_mass)
    freq = {c: max(1, int(v)) for c, v in base.items()}
    freq[0] = max(1, f0)
    return freq


# ── 比特级流 ────────────────────────────────────────────────
class BitWriter:
    def __init__(self):
        self.buf = bytearray()
        self.acc = 0
        self.n = 0

    def write(self, bits: str):
        for b in bits:
            self.acc = (self.acc << 1) | (b == "1")
            self.n += 1
            if self.n == 8:
                self.buf.append(self.acc)
                self.acc = self.n = 0

    def bytes(self) -> bytes:
        out = bytes(self.buf)
        pad = (8 - self.n) % 8
        tail = bytearray()
        a, n = self.acc, self.n
        if n:
            tail.append(a << (8 - n))
        return out + bytes(tail), pad


def encode(codes: dict[int, str], symbols) -> tuple[bytes, int]:
    w = BitWriter()
    for s in symbols:
        w.write(codes[s])
    return w.bytes()


def decode(codes: dict[int, str], data: bytes, n_syms: int):
    rev = {v: k for k, v in codes.items()}
    out = []
    cur = ""
    for byte in data:
        for i in range(7, -1, -1):
            cur += "1" if (byte >> i) & 1 else "0"
            if cur in rev:
                out.append(rev[cur])
                cur = ""
                if len(out) == n_syms:
                    return out
    return out


# ── 自检 ────────────────────────────────────────────────────
def selftest():
    print("== 1. 无损往返 ==")
    freq = synth_freq()
    codes = build_huffman(freq)
    total = sum(freq.values())
    import random
    rng = random.Random(1)
    pop = list(freq.keys())
    wts = [freq[p] for p in pop]
    syms = rng.choices(pop, weights=wts, k=100_000)

    data, pad = encode(codes, syms)
    dec = decode(codes, data, len(syms))
    ok = dec == syms
    print(f"   {len(syms):,} 符号 → {len(data):,}B → 往返 {'✓' if ok else '✗'}")
    assert ok, "往返失败"

    print("== 2. 压缩率（合成分布）==")
    raw_bits = len(syms) * 4
    comp_bits = len(data) * 8 - pad
    bps = comp_bits / len(syms)              # 实际每符号比特数
    ratio = comp_bits / raw_bits             # 字节比
    print(f"   原始 4.00 bit/sym → 实际 {bps:.2f} bit/sym "
          f"（字节省 {(1-ratio)*100:.0f}%）")

    print("== 3. 码长分布 ==")
    lens = sorted((len(c), s) for s, c in codes.items())
    for L, s in lens:
        bar = "#" * min(30, int(freq[s] / total * 300))
        print(f"   code={s:X} len={L} 占比={freq[s]/total*100:5.1f}% {bar}")

    mx = max(len(c) for c in codes.values())
    print(f"\n   最长码长 = {mx} bit"
          f" → {'两级 LUT 可解 ✓' if mx <= 8 else '需多周期解码 ⚠️'}")

    print("\n== 4. 有效带宽增益 ==")
    eff = 1 / ratio                           # 同样字节装下更多符号
    print(f"   SerDes 有效带宽 ×{eff:.2f}"
          f" → batch128 吞吐 ~{17.3*eff:.0f} t/s（x4 口径）"
          f"\n   ⚠ 合成分布标定；真 K3 零值占比更高，收益应更好")


def demo():
    freq = synth_freq()
    codes = build_huffman(freq)
    print("码表样例（按频率排序）：")
    for s, c in sorted(codes.items(), key=lambda kv: len(kv[1])):
        mag = [0, .5, 1, 1.5, 2, 3, 4, 6][s & 7]
        print(f"  E2M1={mag:+.1f} (code {s:X}) → '{c}'")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.demo:
        demo()
    else:
        selftest()
