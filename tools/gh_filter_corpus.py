#!/data/data/com.termux/files/usr/bin/python3
"""gh_filter_corpus.py — 对抓取的 GitHub 代码语料做质量筛选.

背景 (tools/gh_fetch_corpus.py 抓下来的 4348 文件实测):
  - 仓库极度失衡: cpython 占 48.9%, scikit-learn 占 19.8%, 两家合计近 70%
  - 测试文件占 53.6% (体积 58.2%) —— 语法模式单一 (assert/参数化/fixture),
    对小模型信噪比很差
  - 好代码的信号: 62.8% 含类型标注, 44.5% 含 docstring

因此筛选目标不是"去脏" (精确重复只有 0.3%, 已经很干净), 而是"纠偏":
  1. 剔除测试文件与构建样板
  2. 单仓库体积上限, 防止一��独大
  3. 尺寸区间过滤 (去样板与巨型数据文件)
  4. 用类型标注/docstring 作为质量加权
  5. 去跨仓库同名副本 (vendored)

用法:
  python3 tools/gh_filter_corpus.py corpus_gh corpus_clean --cap-frac 0.15
"""
import os
import re
import sys
import json
import hashlib
import argparse

TEST_PAT = re.compile(
    r"(^|[_/])tests?([_/]|$)|(^|[_/])test_[^/]*\.py$|[^/]*_test\.py$|"
    r"conftest\.py$|/testing?/", re.I)
BOILER_PAT = re.compile(
    r"(^|/)(setup|versioneer|noxfile|conftest|tox)\.py$|"
    r"(^|/)__init__\.py$|_version\.py$|\.pb\.go\.py$", re.I)
DOCS_PAT = re.compile(r"(^|/)docs?/|mkdocs\.conf\.py$|(^|/)conf\.py$", re.I)
# 类型标注: 函数签名返回值 / 变量注解
TYPE_PAT = re.compile(r"->\s*[\w\.\[\], |]+:|:\s*(int|str|float|bool|bytes|"
                      r"List|Dict|Optional|Sequence|Iterator|Tuple|Any|"
                      r"Union|Path|os\.PathLike)\b")
DOCSTR_PAT = re.compile(r'("""|\'\'\')')


def classify(name, text):
    if TEST_PAT.search(name):
        return "test"
    if BOILER_PAT.search(name):
        return "boiler"
    if DOCS_PAT.search(name):
        return "docs"
    return "src"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--cap-frac", type=float, default=0.15,
                    help="单仓库体积占总量上限")
    ap.add_argument("--min-bytes", type=int, default=1000)
    ap.add_argument("--max-bytes", type=int, default=150_000)
    ap.add_argument("--require-type", action="store_true", default=True)
    ap.add_argument("--keep-tests", action="store_true")
    ap.add_argument("--report", default=None)
    a = ap.parse_args()

    os.makedirs(a.dst, exist_ok=True)
    recs = []
    for fn in os.listdir(a.src):
        p = os.path.join(a.src, fn)
        if not os.path.isfile(p):
            continue
        sz = os.path.getsize(p)
        if not (a.min_bytes <= sz <= a.max_bytes):
            continue
        try:
            text = open(p, encoding="utf-8").read()
        except Exception:
            continue
        repo = fn.split("__")[0]
        subpath = fn.split("__", 1)[1] if "__" in fn else fn
        recs.append({"fn": fn, "repo": repo, "sub": subpath, "size": sz,
                     "cat": classify(subpath, text), "text": text,
                     "typed": bool(TYPE_PAT.search(text)),
                     "doc": bool(DOCSTR_PAT.search(text))})
    total_in = sum(r["size"] for r in recs)
    print(f"[读入] {len(recs)} 文件 / {total_in/1e6:.1f} MB")

    by_cat = {}
    for r in recs:
        by_cat.setdefault(r["cat"], []).append(r)
    for c, rs in sorted(by_cat.items(), key=lambda kv: -len(kv[1])):
        print(f"   {c:7s} {len(rs):5d} 文件  {sum(r['size'] for r in rs)/1e6:6.1f} MB")

    # 1) 去跨仓库同名副本 (vendored / fork)
    seen_sub, dedup = set(), []
    for r in sorted(recs, key=lambda r: (-r["typed"], -r["doc"], -r["size"])):
        if r["sub"] in seen_sub:
            continue
        seen_sub.add(r["sub"])
        dedup.append(r)
    print(f"[去同名副本] {len(recs)} -> {len(dedup)}")

    # 2) 去测试 / 样板
    keep = [r for r in dedup if a.keep_tests or r["cat"] == "src"]
    print(f"[去测试/样板] {len(dedup)} -> {len(keep)}")

    # 3) 质量优先: 分层采样, 保证多样性而不是只留最大的
    keep.sort(key=lambda r: (not r["typed"], not r["doc"], -r["size"]))

    # 4) 单仓库配额: 动态判定 —— 只有当该仓库当前占比仍低于 cap 时才接受,
    #    这样占比是对"已选结果"而言, 而不是对输入总量 (按输入算会让配额形同虚设,
    #    因为第一轮每仓库上限 = quota/2 可能覆盖整个仓库)
    out, per_repo, used = [], {}, 0.0
    for r in keep:
        cur = per_repo.get(r["repo"], 0)
        if used and (cur + r["size"]) > a.cap_frac * (used + r["size"]):
            continue
        out.append(r)
        per_repo[r["repo"]] = cur + r["size"]
        used += r["size"]
    print(f"[配额] 单仓上限 {a.cap_frac:.0%} -> 保留 {len(out)} 文件 "
          f"{used/1e6:.1f} MB, 覆盖 {len(per_repo)} 仓库")

    n_typed = sum(1 for r in out if r["typed"])
    n_doc = sum(1 for r in out if r["doc"])
    for r in out:
        with open(os.path.join(a.dst, r["fn"]), "w", encoding="utf-8") as f:
            f.write(r["text"])
    print(f"[写出] {a.dst}: {len(out)} 文件 / {used/1e6:.1f} MB")
    print(f"       含类型标注 {n_typed} ({100*n_typed/max(len(out),1):.0f}%), "
          f"含 docstring {n_doc} ({100*n_doc/max(len(out),1):.0f}%)")
    print("       仓库分布:")
    for repo, s in sorted(((k, sum(r["size"] for r in out if r["repo"] == k))
                           for k in per_repo), key=lambda kv: -kv[1])[:12]:
        n = sum(1 for r in out if r["repo"] == repo)
        print(f"         {repo:28s} {n:4d} 文件 {s/1e6:6.2f} MB "
              f"{100*s/max(used,1):4.1f}%")
    if a.report:
        json.dump({"files": len(out), "bytes": used,
                   "repos": len(per_repo)}, open(a.report, "w"))


if __name__ == "__main__":
    main()