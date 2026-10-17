#!/data/data/com.termux/files/usr/bin/python3
"""eval_humaneval.py — 在 HumanEval 上评估, 但**目标不是拿分数**.

原计划是报 pass@1. 但 Codex-12M(12M 参数) 只有 2.6%, GPT-Neo 125M 只有 6.4%,
0.57M 预期 pass@1 < 1% —— 报一个 0% 没有信息量.

所以这里测三件更基础、能给出确定答案的事:

  1. **语法有效率**   输出能不能被 Python `ast.parse` 接受
     -> 今晚的输出是 `print(f.add(102))` 这种, 能不能被解释器接受是未知的
  2. **可运行率**     拼上 test 后能不能真的跑起来(不报错)
  3. **pass@1**      真的对了的 —— 预期极低, 但作为参照点记录

同时报告与原论文基线的距离: TabNine≈Codex-12M 2.6% / GPT-Neo 125M 6.4%.
"""
import argparse
import json
import multiprocessing as mp
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def build_program(completion, row):
    return row["prompt"] + completion + "\n" + row["test"] + \
        "\ncheck(%s)\n" % row["entry_point"]


def _run(code, q):
    import contextlib
    import io
    try:
        g = {"__name__": "__main__"}
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            exec(compile(code, "<gen>", "exec"), g)
        q.put(("ok", ""))
    except SyntaxError as e:
        q.put(("syntax", "line %s: %s" % (e.lineno, e.msg)))
    except BaseException as e:               # noqa: BLE001
        q.put(("run", "%s: %s" % (type(e).__name__, str(e)[:80])))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ckpt", required=True)
    ap.add_argument("--tokens", required=True)
    ap.add_argument("--vocab", type=int, default=2400)
    ap.add_argument("--data", required=True)
    ap.add_argument("--n", type=int, default=164)
    ap.add_argument("--max-new", type=int, default=160)
    ap.add_argument("--temp", type=float, default=0.0)
    ap.add_argument("--topk", type=int, default=0)
    a = ap.parse_args()

    import sampler
    from a3_pretrain import compress_vocab
    from qxn_train import build_from_ckpt

    ids = np.load(a.tokens)["ids"]
    seq, V, K = compress_vocab(ids, a.vocab)
    lut = np.zeros(int(K.max()) + 2, np.int64)
    lut[K] = np.arange(1, K.size + 1)
    z = np.load(a.ckpt)
    mode = str(z["mode"]) if "mode" in z.files else "fp32"
    m, info = build_from_ckpt({k: z[k] for k in z.files}, mode=mode)
    _, _, _, VV, BLK = info
    print("[he] ckpt=%s mode=%s V=%d blk=%d  %s"
          % (os.path.basename(a.ckpt), mode, VV, BLK, sampler.describe()))

    rows = [json.loads(l) for l in open(a.data, encoding="utf-8") if l.strip()][:a.n]
    rng = np.random.default_rng(0)
    stat = {"syntax": 0, "ok": 0, "run": 0, "empty": 0}
    pass_at_1 = 0
    shown = 0
    for row in rows:
        toks = z_ = None
        try:
            pt = json.loads(row["prompt"]) if False else None
        except Exception:
            pass
        # prompt 转成 token（Q4T 词表 -> 压缩槽）；词表外的丢弃
        from q1t_stream import StreamEngine
        if toks is None:
            toks = _encode(row["prompt"], lut)
        if not toks:
            stat["empty"] += 1
            continue
        toks = toks[-BLK:]
        for _ in range(a.max_new):
            lg = np.asarray(m.forward(np.array([toks[-BLK:]], np.int64),
                                     collect=False)[0], np.float64)[-1]
            nxt = sampler.pick(lg, toks, rng)
            if nxt == 0:            # UNK: 退化为最高频真实 token
                nxt = int(np.argmax(lg[1:]) + 1)
            toks.append(nxt)
        comp = _decode(toks[len(toks) - a.max_new:], lut, K)
        code = build_program(comp, row)
        q = mp.Queue()
        p = mp.Process(target=_run, args=(code, q))
        p.start()
        p.join(6)
        if p.is_alive():
            p.terminate()
            res = ("run", "timeout")
        elif q.empty():
            res = ("run", "crash")
        else:
            res = q.get()
        stat[res[0]] = stat.get(res[0], 0) + 1
        if res[0] == "ok":
            pass_at_1 += 1
        if shown < 3:
            print("\n--- %s ---" % row["entry_point"])
            print("生成(前 200 字符): %r" % comp[:200])
            print("判定: %s %s" % (res[0], res[1][:60]))
            shown += 1

    n = len(rows)
    print("\n=== HumanEval (%d 题, 每题生成 %d token) ===" % (n, a.max_new))
    print("  语法错误   %3d  (%5.1f%%)" % (stat["syntax"], 100 * stat["syntax"] / n))
    print("  运行时报错 %3d  (%5.1f%%)" % (stat["run"], 100 * stat["run"] / n))
    print("  通过       %3d  (%5.1f%%)  ← pass@1" % (pass_at_1, 100 * pass_at_1 / n))
    ok_syntax = n - stat["syntax"] - stat["empty"]
    print("  语法有效率 %5.1f%%   (n - 语法错 - 空)"
          % (100 * ok_syntax / max(n - stat["empty"], 1)))
    print("\n  参照: Codex-12M 2.6% / GPT-Neo 125M 6.4% (arXiv:2107.03374)")


_ENC = [None]


def _encode(text, lut):
    from q1t_stream import StreamEngine
    if _ENC[0] is None:
        _ENC[0] = StreamEngine(
            slim="/data/data/com.termux/files/home/models/qxt/"
                 "rStar-Coder-Qwen3-0.6B.Q8_0-Q4T_packslim.gguf")
    ids = [int(t) for t in _ENC[0].encode(text)]
    return [int(lut[i]) for i in ids if lut[i] != 0]


def _decode(slots, lut, keep):
    """槽 -> Q4T 原始 token id -> 文本(必须走 tokenizer 的 decode_text,
    原始 id 是词表索引最大 151936, 不能当字节用)."""
    if _ENC[0] is None:
        _encode("", lut)
    real = [int(keep[i - 1]) for i in slots if 1 <= i < keep.size + 1]
    return _ENC[0].decode_text(real)


if __name__ == "__main__":
    main()