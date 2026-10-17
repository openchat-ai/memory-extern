#!/data/data/com.termux/files/usr/bin/python3
"""magicoder_a3.py — 从 Magicoder-Evol-Instruct-110K 抽取 A3 训练集.

A3 = instruction + response 中的 python 代码块 (去掉散文解释).
理由: 我们要训的是"读指令 -> 产代码"的映射, 而 A1(全文) 混入 29% 指令语料
和大量非代码语言, A2(纯代码) 又丢掉了指令-代码的对齐关系.

统计依据 (抽样 40000 条):
  instruction 平均 647 字符 / response 平均 1545 字符 / 79.5% 含代码块
  代码块语言: python 52.8%, javascript 7.6%, sql 5.3%, java 4.3%, ...

用法:
  python3 tools/magicoder_a3.py magicoder.jsonl a3.jsonl
"""
import os
import re
import sys
import json
import hashlib

BLOCK = re.compile(r"```(?:python|py|python3)\s*\n(.*?)```", re.S)
ANY_BLOCK = re.compile(r"```(\w*)\s*\n(.*?)```", re.S)


def main():
    src = sys.argv[1]
    dst = sys.argv[2]
    min_code = int(sys.argv[3]) if len(sys.argv) > 3 else 60
    max_chars = int(sys.argv[4]) if len(sys.argv) > 4 else 6000
    n_out = n_skip = 0
    seen = set()
    chars_instr = chars_code = 0
    with open(src, encoding="utf-8") as f, \
         open(dst, "w", encoding="utf-8") as g:
        for line in f:
            try:
                r = json.loads(line)
            except Exception:
                n_skip += 1
                continue
            instr = (r.get("instruction") or "").strip()
            resp = r.get("response") or ""
            codes = [c.strip() for c in BLOCK.findall(resp)]
            if not codes:                       # 没标 python 语言的块再兜底
                for lang, body in ANY_BLOCK.findall(resp):
                    if lang.lower() in ("", "py", "python"):
                        codes.append(body.strip())
            codes = [c for c in codes if len(c) >= min_code]
            if not instr or not codes:
                n_skip += 1
                continue
            code = "\n\n".join(codes)
            doc = instr + "\n\n" + code
            if len(doc) > max_chars:
                n_skip += 1
                continue
            h = hashlib.md1 if False else hashlib.md5(doc.encode()).hexdigest()
            if h in seen:                      # 进化蒸馏易产生近重复
                n_skip += 1
                continue
            seen.add(h)
            g.write(json.dumps({"instruction": instr, "code": code},
                               ensure_ascii=False) + "\n")
            chars_instr += len(instr)
            chars_code += len(code)
            n_out += 1
            if n_out % 20000 == 0:
                print(f"  {n_out} 条 ({(chars_instr+chars_code)/1e6:.0f} MB)",
                      flush=True)
    tot = chars_instr + chars_code
    print(f"[A3] 保留 {n_out} 条 / 跳过 {n_skip}")
    print(f"     指令 {chars_instr/1e6:.1f} MB ({100*chars_instr/tot:.0f}%) + "
          f"代码 {chars_code/1e6:.1f} MB ({100*chars_code/tot:.0f}%)")
    print(f"     合计 {tot/1e6:.1f} MB -> 约 {tot/2.28/1e6:.1f}M tokens")
    print(f"     写出 {dst} ({os.path.getsize(dst)/1e6:.1f} MB)")


if __name__ == "__main__":
    main()