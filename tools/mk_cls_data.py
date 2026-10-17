#!/data/data/com.termux/files/usr/bin/python3
"""mk_cls_data.py — 代码行分类数据(标签由语法自动生成, 零人工标注).

动机(§37): §36 证明模型学不了加法(算法), 但它在 §33 已经证明
能逐字节复现上下文(induction). 所以让模型做**感知/分类**, 算法交给代码.

每条样本 = 一个定长窗口, 格式:
    <上文>\\n@@<当前行>\\n@C        -> 标签字符
标签 8 类, 由 Python 语法直接判定, 不需要人标:
    I import / M from-import
    D def / C class
    R return / yield
    A 赋值(=开头) / P 参数或调用(行尾)
    T 注释(#开头)
    B 空行 / 其余
标签字符本身也在文本里出现(当前行), 所以不额外增加词表.
"""
import argparse
import json
import re

import numpy as np

LABELS = "IMDRAPTB"          # 8 类


def label_of(line):
    s = line.strip()
    if not s:
        return "B"
    if s.startswith("#"):
        return "T"
    if re.match(r"^(import|from)\s", s):
        return "I"
    if re.match(r"^(def|class|async def)\s", s):
        return "D"
    if re.match(r"^(return|yield)\b", s):
        return "R"
    if re.match(r"^[\w\.\[\]\"']+\s*=[^=]", s):
        return "A"
    if re.search(r"\)\s*:?$", s):
        return "P"
    return "B"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", default="/data/data/com.termux/files/home/sram/"
                    "magicoder_a3.jsonl")
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=600_000, help="样本数")
    ap.add_argument("--ctx", type=int, default=28, help="上文行数")
    ap.add_argument("--max-line", type=int, default=0, help="当前行截断长度, 0=不截断")
    ap.add_argument("--sep", default="\n#8<#\n", help="样本分隔符")
    a = ap.parse_args()

    rng = np.random.default_rng(31337)
    out = bytearray()
    cnt = {c: 0 for c in LABELS}
    with open(a.jsonl, encoding="utf-8") as f:
        for line in f:
            if len(out) >= a.n * 80:
                break
            code = json.loads(line)["code"]
            ls = code.split("\n")
            if len(ls) < 6:
                continue
            for i in range(a.ctx, len(ls)):
                cur = ls[i]
                if not cur.strip():
                    continue
                lab = label_of(cur)
                ctx = "\n".join(ls[i - a.ctx:i])
                if len(ctx) > 700:
                    ctx = ctx[-700:]
                line = cur[:a.max_line] if a.max_line else cur
                s = f"{ctx}\n@@{line}\n@{lab}"
                if len(s) > 800:
                    s = s[-800:]
                # 样本之间必须隔开, 否则上一条的 "@标签" 会漏进下一条上文,
                # 让模型学到"上文里本来就该有标签"的错误模式.
                out += a.sep.encode() + s.encode("utf-8", "ignore")
                cnt[lab] += 1
    arr = np.frombuffer(bytes(out), np.uint8).astype(np.int32) + 1
    np.savez(a.out, ids=arr)
    tot = sum(cnt.values())
    print(f"[cls] {tot:,} 样本 / {len(arr):,} 字节  ({a.out})")
    print("[cls] 类别分布: " + "  ".join(
        f"{k} {100*v/max(tot,1):.1f}%" for k, v in cnt.items()))


if __name__ == "__main__":
    main()