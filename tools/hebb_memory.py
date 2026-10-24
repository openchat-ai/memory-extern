"""hebb_memory.py — 运行时事实记忆层（零训练）.

背景（docs/HEB_EXPERIMENT.md §10.12）:
  FFN 权重写入只能占掉"下一个 token"，无法让事实在别处被查询（桥接 rank 425→37）。
  事实一旦在 KV/上下文路径上，引擎就会用它推理（Berlin rank 0）。
  => 本模块把事实做成**运行时注入**，而不是烘进 GGUF。

机制:
  1. 事实库: (key, value) —— key 是"事实的提问句"，value 是答案
  2. 检索: **token 级 IDF 加权重合** —— 年份/专名是低 df token，权重高
     （实测 φ-cosine 不可用: 同模板 key 的 cos ≈ 0.98，无关句反而分更高, §10.11.6）
  3. 注入: 检索到就把事实拼进提示, 交给原模型生成
  4. 阈值: 分数不够就**不注入**，退回 base 回答
  5. 控制层 (§10.19): 置信度边际**不可用**（与正确性反相关）→ 改为
     **分解式**（记忆只给"年份->国家"，"国家->首都"交还模型）
     + 双模板并行 + 冲突时反向校验仲裁

用法:
  python tools/hebb_memory.py --demo
  from hebb_memory import HebbMemory
  m = HebbMemory().add("The country where the 1974 FIFA World Cup was held is", "Germany")
  m.answer("What is the capital city of that country?",
           context="The country where the 1974 FIFA World Cup was held is")
"""
import argparse
import json
import math
import os
import sys
from collections import Counter

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hebb_write import HebbWriter

TEMPLATE = "{key} {value}.\n{q}\nAnswer:"

# 分解式: 记忆只提供"年份->国家", "国家->首都" 交还模型
# 实测 (10 条): "The capital of {v} is" 9/10, "{v}'s capital city is" 9/10,
# 且失败项互补 (Sweden / Chile). 联合式失败项 (1986/1994) 的输出都在复读事实.
ATTR_TEMPLATES = ["The capital of {v} is", "{v}'s capital city is"]


class HebbMemory:
    def __init__(self, n_ctx=512, threshold=0.35, tau_base=0.0, margin=0.0):
        self.H = HebbWriter(n_ctx=n_ctx)
        self.E = self.H.eng
        self.threshold = threshold
        self.tau_base = tau_base      # 基线平均 logprob 阈值 (0 = 从不提前采信)
        self.margin = margin          # 接受记忆所需超出量
        self.evidence = {}
        self.facts = []
        self._toks = []
        self._df = Counter()

    def _tok(self, text):
        ids = list(self.E.encode(text))
        grams = {("t", x) for x in ids}
        grams |= {("b", a, b) for a, b in zip(ids, ids[1:])}
        return grams

    def add(self, key, value):
        self.facts.append({"key": key, "value": value})
        t = set(self._tok(key))
        self._toks.append(t)
        for x in t:
            self._df[x] += 1
        return self

    def load(self, path):
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    d = json.loads(line)
                    self.add(d["key"], d["value"])
        return self

    def save(self, path):
        with open(path, "w") as f:
            for d in self.facts:
                f.write(json.dumps(d, ensure_ascii=False) + "\n")

    def _idf(self, tok):
        n = len(self.facts)
        return math.log((n + 1) / (self._df.get(tok, 0) + 1)) + 1.0

    def _score(self, query, key_toks):
        q = self._tok(query)
        if not q:
            return 0.0
        # 未见过的 bigram/单 token = 库外信号 -> 硬拒绝 (防 1954 命中 1958)
        if any(self._df.get(t, 0) == 0 for t in q):
            return 0.0
        shared = sum(self._idf(t) for t in q & key_toks)
        total = sum(self._idf(t) for t in q)
        return shared / total if total else 0.0

    def retrieve(self, query, k=1):
        if not self.facts:
            return []
        sims = [(self._score(query, kt), i) for i, kt in enumerate(self._toks)]
        sims.sort(reverse=True)
        return [{"sim": s, **self.facts[i]} for s, i in sims[:k]]

    @staticmethod
    def _echoes(text, fact):
        """联合式输出是否在复读事实 (年份或 value 原样出现)."""
        import re
        tl = text.lower()
        if fact["value"].lower() in tl:
            return True
        return any(y in tl for y in re.findall(r"(?:19|20)\d{2}", fact["key"]))

    @staticmethod
    def _cand(text):
        """从"Gothenburg. The capital of"里取出候选实体."""
        import re
        s = text.strip()
        s = re.sub(r"^(called|a|an|the)\s+", "", s, flags=re.I)
        m = re.match(r"([A-Z][\w.\-]*(?:\s+[A-Z][\w.\-]*)*)", s)
        return m.group(1).strip() if m else ""

    def _reverse_ok(self, cand, value):
        """反向校验: '<cand> is the capital of' 是否回到 value (双向一致)."""
        if not cand:
            return False
        text, _, _ = self._gen(f"{cand} is the capital of", 6)
        return value.lower() in text.lower()

    def _answer_attr(self, value, n_new=8):
        """两种格式 + 冲突时用反向校验仲裁 (实测修复 Sweden: Gothenburg/Stockholm)."""
        outs = []
        for t in ATTR_TEMPLATES:
            text, lp, _ = self._gen(t.format(v=value), n_new)
            outs.append((text.strip(), lp))
        if len(outs) == 2:
            a, b = self._cand(outs[0][0]), self._cand(outs[1][0])
            if a and b and a.lower() != b.lower():
                ok = [self._reverse_ok(a, value), self._reverse_ok(b, value)]
                if ok[0] != ok[1]:
                    return outs[ok.index(True)][0], "reverse"
        return max(outs, key=lambda x: x[1])[0], "lp"

    # ---------- 控制层 (docs §10.18.4): 生成 + 置信度 ----------

    def _gen(self, prompt, n_new, temperature=0.01):
        """贪心生成, 返回 (文本, 平均 logprob, 首 token 边际)."""
        ids = list(self.E.encode(prompt))
        lg, cache = self.E.forward(np.array(ids, np.int64))
        out, lps = [], []
        for _ in range(n_new):
            z = lg.astype(np.float64)
            mx = z.max()
            lse = mx + math.log(np.exp(z - mx).sum())
            t = int(np.argmax(z))
            lps.append(float(z[t] - lse))
            out.append(t)
            ids.append(t)
            lg, cache = self.E.forward(np.array(ids, np.int64), cache)
        top2 = np.sort(lg.astype(np.float64))[-2:]
        return (self.E.decode_text(out), float(np.mean(lps)),
                float(top2[1] - top2[0]))

    def answer(self, question, context=None, n_new=24, threshold=None,
               tau_base=None, margin=None, force_memory=False):
        """控制策略: 基线高置信 -> 不查; 否则检索 -> 与基线比边际 -> 接受/回滚.

        tau_base: 基线平均 logprob 高于此值则直接采信 (不依赖记忆)
        margin  : 记忆路径要比基线高出的 logprob
        stat=True 时额外返回两路置信度 (标定用)
        """
        th = self.threshold if threshold is None else threshold
        tau_base = self.tau_base if tau_base is None else tau_base
        margin = self.margin if margin is None else margin
        info = {}

        base_text, base_lp, _ = self._gen(question, n_new)
        info["base_lp"] = base_lp
        if base_lp >= tau_base and not force_memory:
            info.update(used=None, sim=None, route="base-confident", text=base_text)
            return info

        hits = self.retrieve(context or question, k=1)
        best = hits[0] if hits else None
        if best is None or best["sim"] < th:
            info.update(used=None, sim=None if best is None else best["sim"],
                        route="no-memory", text=base_text)
            return info

        prompt = TEMPLATE.format(key=best["key"], value=best["value"], q=question)
        joint, joint_lp, _ = self._gen(prompt, n_new)
        dec, how = (self._answer_attr(best["value"]) if self._attr_of(question)
                    else ("", "n/a"))
        dec_lp = -1e9
        info.update(sim=best["sim"], base_text=base_text, joint=joint,
                    decomposed=dec, joint_lp=joint_lp, attr_how=how)
        rec = self.evidence.setdefault(best["key"], {"uses": 0, "accepted": 0})
        rec["uses"] += 1
        # 控制: 能分解则分解; 否则用联合式, 但复读事实时标记
        if dec:
            text, route = dec, "decomposed"
        elif self._echoes(joint, best):
            text, route = joint, "joint-echo"
        else:
            text, route = joint, "joint"
        rec["accepted"] += 1
        info.update(used=best, route=route, text=text)
        return info

    @staticmethod
    def _attr_of(question):
        q = question.lower()
        return "capital" if "capital" in q else None

    def retire(self, min_uses=3):
        """淘汰: 用过 >= min_uses 且从未被接受的事实."""
        drop = {k for k, v in self.evidence.items()
                if v["uses"] >= min_uses and v["accepted"] == 0}
        if not drop:
            return []
        keep = [i for i, f in enumerate(self.facts) if f["key"] not in drop]
        self.facts = [self.facts[i] for i in keep]
        self._toks = [self._toks[i] for i in keep]
        self._df = Counter()
        for t in self._toks:
            for x in t:
                self._df[x] += 1
        return sorted(drop)


FACTS = [
    ("The country where the 1958 FIFA World Cup was held is", "Sweden", "Stockholm"),
    ("The country where the 1962 FIFA World Cup was held is", "Chile", "Santiago"),
    ("The country where the 1966 FIFA World Cup was held is", "England", "London"),
    ("The country where the 1974 FIFA World Cup was held is", "Germany", "Berlin"),
    ("The country where the 1978 FIFA World Cup was held is", "Argentina", "Buenos Aires"),
    ("The country where the 1982 FIFA World Cup was held is", "Italy", "Rome"),
    ("The country where the 1986 FIFA World Cup was held is", "Mexico", "Mexico City"),
    ("The country where the 1990 FIFA World Cup was held is", "Italy", "Rome"),
    ("The country where the 1994 FIFA World Cup was held is", "United States", "Washington"),
    ("The country where the 1998 FIFA World Cup was held is", "France", "Paris"),
]

CTX = "The country where the {y} FIFA World Cup was held is"
Q_CAP = "What is the capital city of that country?"


def demo():
    m = HebbMemory()
    for key, val, _ in FACTS:
        m.add(key, val)
    print(f"[store] {len(m.facts)} 条事实", flush=True)

    ok = 0
    print("\n=== 桥接: 检索(上下文里的年份) -> 注入 -> 用事实答首都 ===", flush=True)
    for key, val, cap in FACTS:
        y = key.split("the ")[1].split(" ")[0]
        r = m.answer(Q_CAP, context=CTX.format(y=y))
        hit = (r["used"] is not None and r["used"]["key"] == key)
        good = hit and cap.lower() in r["text"].lower()
        ok += good
        print(f"  {y}  sim={r['sim']:.2f} 检索={'OK' if hit else 'WRONG'} "
              f"[{r['route']:10s}] 答={r['text'][:28]!r:30s} 期望{cap!r} "
              f"{'OK' if good else 'FAIL'}", flush=True)
    print(f"[桥接] {ok}/{len(FACTS)}", flush=True)

    print("\n=== 直接召回 ===", flush=True)
    for key, val, _ in FACTS[:3]:
        y = key.split("the ")[1].split(" ")[0]
        r = m.answer(key, context=key, n_new=8)
        good = val.lower() in r["text"].lower()
        print(f"  {y} -> {r['text'][:26]!r:28s} 期望{val!r} {'OK' if good else 'FAIL'}", flush=True)

    print("\n=== 无关问句 (不应注入) ===", flush=True)
    r = m.answer("The color of the sky is", n_new=12)
    print(f"  sim={r['sim']:.2f} used={r['used']} gen={r['text']!r}", flush=True)
    print(f"  {'OK (未注入)' if r['used'] is None else 'FAIL (误注入)'}", flush=True)

    print("\n=== 库外年份 (不应注入) ===", flush=True)
    r = m.answer(Q_CAP, context=CTX.format(y="1954"), n_new=12)
    print(f"  sim={r['sim']:.2f} used={r['used']} gen={r['text']!r}", flush=True)
    print(f"  {'OK (未注入)' if r['used'] is None else 'FAIL (误注入)'}", flush=True)
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--demo", action="store_true")
    ap.add_argument("--store")
    ap.add_argument("--q")
    ap.add_argument("--context")
    ap.add_argument("--threshold", type=float, default=0.35)
    args = ap.parse_args()
    if args.demo:
        return demo()
    m = HebbMemory(threshold=args.threshold)
    if args.store:
        m.load(args.store)
    if args.q:
        print(json.dumps(m.answer(args.q, context=args.context),
                         ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
