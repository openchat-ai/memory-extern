#!/data/data/com.termux/files/usr/bin/python3
"""eval_bitwidths.py — QxT 各位宽端到端生成对照 (贪心解码).

对同一组 prompt, 用标准 Qwen3 chat template 跑 Q1T/Q2T/Q3T/Q4T slim 包,
输出每档的生成文本与 tok/s, 用于横向比较 (可与 llama-cli ground truth 对照).

用法:
    PYTHONPATH=tools python3 tools/eval_bitwidths.py [位宽,逗号分隔] [n_new]
    PYTHONPATH=tools python3 tools/eval_bitwidths.py 1,2,3,4 28
"""
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from q1t_stream import StreamEngine

MODELS = ("/data/data/com.termux/files/home/models/qxt/"
          "rStar-Coder-Qwen3-0.6B.Q8_0-Q{b}T_packslim.gguf")

IM_START, IM_END = 151644, 151645
SYS_THINK = "You are Qwen3. You are a helpful assistant."
SYS_NOTHINK = "You are Qwen3. You are a helpful assistant. /no_think"

PROMPTS = (
    ("1+1=?", False),
    ("What is the capital of France?", False),
    ("def fib(n):", False),
    ("1+1=?", True),
)


def check_bpe(E):
    """BPE 自检: roundtrip 对 BPE 无效 (decode 是拼接), 必须查 token 数.

    历史教训: 曾因逐字符 merge 导致 'You' 被拆成 3 个 token, roundtrip
    仍通过但模型输出全面退化 (见 docs/QXT_QUANT_DISTILL_LOG.md §12.10).
    """
    cases = [
        ("You", 1), ("The", 1), ("def", 1), ("Paris", 1),
        ("hello", 1), ("world", 1),
    ]
    bad = []
    for text, want in cases:
        n = len(E.encode(text))
        if n != want:
            bad.append((text, n, want))
    # 整词必须被合并成单 token
    for text in ("You are", "The capital", "def fib"):
        ids = E.encode(text)
        if len(ids) < 2:
            bad.append((text, len(ids), ">=2"))
    if bad:
        print("  [BPE 自检失败] " + "; ".join(
            f"{t!r}->{n} tok (期望 {w})" for t, n, w in bad), flush=True)
        return False
    print("  [BPE 自检通过]", flush=True)
    return True


def build_ids(eng, user, think):
    sysmsg = SYS_THINK if think else SYS_NOTHINK
    return ([IM_START] + eng.encode(sysmsg) + [IM_END, IM_START]
            + eng.encode("user\n" + user) + [IM_END, IM_START]
            + eng.encode("assistant\n"))


def gen(eng, ids, n_new):
    lg, cache = eng.forward(np.array(ids, np.int64))
    out = []
    t0 = time.time()
    for _ in range(n_new):
        ti = int(lg.argmax())
        out.append(ti)
        lg, cache = eng.forward(np.array(list(ids) + out, np.int64), cache)
    return out, time.time() - t0


def main():
    bits = [int(x) for x in (sys.argv[1] if len(sys.argv) > 1 else "4").split(",")]
    n_new = int(sys.argv[2]) if len(sys.argv) > 2 else 24
    for b in bits:
        path = MODELS.format(b=b)
        if not os.path.exists(path):
            print(f"[skip] Q{b}T 缺失: {path}")
            continue
        print(f"===== Q{b}T  ({os.path.getsize(path)/1e6:.1f} MB) =====",
              flush=True)
        eng = StreamEngine(slim=path)
        check_bpe(eng)
        tot_t, tot_n = 0.0, 0
        for user, think in PROMPTS:
            ids = build_ids(eng, user, think)
            out, dt = gen(eng, ids, n_new)
            tot_t += dt
            tot_n += len(out)
            tag = "think" if think else "nothink"
            print(f"  [{tag}] {user!r} -> {eng.decode_text(out)!r}", flush=True)
        print(f"  speed: {tot_n/tot_t:.2f} tok/s "
              f"({1000*tot_t/tot_n:.1f} ms/token)", flush=True)


if __name__ == "__main__":
    main()