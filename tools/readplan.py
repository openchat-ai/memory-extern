#!/data/data/com.termux/files/usr/bin/python3
"""readplan.py — 把伪矢量 PDF 读回曲线, 测"还剩多少结构".

要回答三个问题:
  Q1  线宽(图层信息)是否保留?   保留 -> 墙/标注可直接分开, 难度大降
  Q2  曲线的几何量级             有多少条? 坐标精度如何?
  Q3  仅凭几何能不能分出"墙"      不看线宽, 只用几何规则
"""
import re
import sys

# AGENTS §12: 真实文件文字层默认脱敏, 姓名/单位/图号一律不打码输出
def redact(t):
    return re.sub(r"[\u4e00-\u9fff]{2,}", "<CJK>", t or "")
from collections import Counter

M2PT = 72.0 / 25.4
NUM = r"[-+]?[\d.]+"


def parse(path):
    from pypdf import PdfReader
    r = PdfReader(path)
    data = r.pages[0].get_contents().get_data().decode("latin-1")
    toks = data.replace("\n", " ").split()
    segs, lw, cur, start, stack = [], None, None, None, []
    i = 0
    while i < len(toks):
        t = toks[i]
        if t == "w" and i >= 1:
            lw = float(toks[i - 1])
        elif t == "m" and i >= 2:
            cur = (float(toks[i - 2]), float(toks[i - 1]))
            start = cur
        elif t == "c" and i >= 6:
            p3 = (float(toks[i - 6]), float(toks[i - 5]))
            p2 = (float(toks[i - 4]), float(toks[i - 3]))
            p1 = (float(toks[i - 2]), float(toks[i - 1]))
            segs.append({"lw": lw, "p0": cur, "p1": p3, "p2": p2, "p3": p1})
            cur = p3
        elif t == "S" and cur is not None and start is not None:
            if abs(cur[0] - start[0]) + abs(cur[1] - start[1]) > 1e-6:
                segs.append({"lw": lw, "p0": cur, "p1": start, "p2": start, "p3": start})
        i += 1
    return segs


def main():
    path = sys.argv[1]
    segs = parse(path)
    print("=== Q2 几何量级 ===")
    print("  曲线段总数: %d" % len(segs))
    xs = [s["p0"][0] for s in segs] + [s["p3"][0] for s in segs]
    ys = [s["p0"][1] for s in segs] + [s["p3"][1] for s in segs]
    print("  坐标范围: x %.0f~%.0f, y %.0f~%.0f (mm)" % (min(xs), max(xs), min(ys), max(ys)))

    print("\n=== Q1 线宽(图层信息)是否保留 ===")
    by = Counter(round(s["lw"], 2) for s in segs if s["lw"] is not None)
    if not by:
        print("  没有线宽信息")
    else:
        for w, n in sorted(by.items()):
            print("  线宽 %.2f pt = %.3f mm   %4d 段 (%4.1f%%)"
                  % (w, w / M2PT, n, 100 * n / len(segs)))
        print("  -> 原始设定: 墙0.50  图框0.70  引线0.18  标注0.13 mm")

    # Q3: 仅凭几何把"长直墙"挑出来
    print("\n=== Q3 只用几何: 挑出长直线段 ===")
    walls, dims, lead = [], [], []
    for s in segs:
        a, b = s["p0"], s["p3"]
        L = ((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5
        s["len"] = L
        if L > 200:
            walls.append(s)
        elif L > 30:
            dims.append(s)
        else:
            lead.append(s)
    print("  长段(>200mm) %d   中段(30-200mm) %d   短段(<30mm) %d"
          % (len(walls), len(dims), len(lead)))
    print("\n  按线宽交叉验证(墙应该是 0.5mm, 标注 0.13mm):")
    for lab, grp in (("长段", walls), ("中段", dims), ("短段", lead)):
        c = Counter(round(s["lw"], 2) for s in grp if s["lw"] is not None)
        print("    %-4s " % lab + "  ".join("%.2fpt×%d" % (w, n) for w, n in sorted(c.items())))


if __name__ == "__main__":
    main()
