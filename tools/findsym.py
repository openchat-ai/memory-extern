#!/data/data/com.termux/files/usr/bin/python3
"""findsym.py — 在真实图纸里找钢筋符号. 只用几何, 不碰文字层 (AGENTS §12).

思路: 字符会在图里重复出现, 所以"高重复 + 形状规整"的子路径簇
      最可能是字符字形。先按形状签名分簇, 再把高频簇 ASCII 画出来。
"""
import collections
import math
import sys

M2PT = 72.0 / 25.4


def parse(path):
    from pypdf import PdfReader
    r = PdfReader(path)
    s = r.pages[0].get_contents().get_data().decode("latin-1", errors="replace")
    tok = s.replace("\n", " ").split()
    lw, nums, cur, subpaths, acc = None, [], None, [], []
    for t in tok:
        try:
            nums.append(float(t))
            continue
        except ValueError:
            pass
        if t == "w" and nums:
            lw = nums[-1]
            nums = []
        elif t == "m" and len(nums) >= 2:
            if acc:
                subpaths.append((lw, acc))
            acc = [(nums[-2], nums[-1])]
            nums = []
        elif t == "l" and len(nums) >= 2 and acc:
            acc.append((nums[-2], nums[-1]))
            nums = []
        else:
            nums = []
    if acc:
        subpaths.append((lw, acc))
    return subpaths


def geom(pts):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    w, h = max(xs) - min(xs), max(ys) - min(ys)
    arc = sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
    # 闭合?
    closed = math.dist(pts[0], pts[-1]) < 1e-6
    return w, h, arc, len(pts) - 1, closed


def render(pts, cw=19, ch=13):
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    sx = (x1 - x0) or 1e-9
    sy = (y1 - y0) or 1e-9
    g = [[" "] * cw for _ in range(ch)]
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        n = max(1, int(math.hypot(bx - ax, by - ay) / (sx / cw)) + 1)
        for k in range(n + 1):
            x = ax + (bx - ax) * k / n
            y = ay + (by - ay) * k / n
            c = int((x - x0) / sx * (cw - 1))
            r = ch - 1 - int((y - y0) / sy * (ch - 1))
            if 0 <= r < ch and 0 <= c < cw:
                g[r][c] = "#"
    return ["".join(r) for r in g]


def main():
    sp = parse(sys.argv[1])
    # 候选: 小尺寸的子路径(字符字形的尺度), 细线优先
    cand = []
    MINSEG = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    for lw, pts in sp:
        if len(pts) < 2:
            continue
        w, h, arc, n, closed = geom(pts)
        wm, hm = w / M2PT * 25.4, h / M2PT * 25.4
        if 0.3 <= max(wm, hm) <= 8.0 and min(wm, hm) > 0.05 and n >= MINSEG:
            cand.append((lw, pts, wm, hm, arc / M2PT * 25.4, n, closed))
    print("候选(0.3~8mm, >=%d段) %d 个" % (MINSEG, len(cand)))

    # 形状签名: 段数 + 长宽比 + 弧长/包围盒, 粗分箱
    def sig(c):
        lw, pts, wm, hm, arc, n, closed = c
        r = (max(wm, hm) / max(min(wm, hm), 1e-6))
        return (n, int(r * 4), int(arc / max(max(wm, hm), 1e-6) * 4), closed)

    groups = collections.defaultdict(list)
    for c in cand:
        groups[sig(c)].append(c)

    print("\n按出现次数排序的高频形状簇 (字符会重复, 所以次数多的最可能是字形):")
    print("  %-28s %6s %8s %8s %8s" % ("签名(段,长宽比,弧长,闭合)", "个数", "宽mm", "高mm", "弧长mm"))
    top = sorted(groups.items(), key=lambda kv: -len(kv[1]))[:8]
    for s, g in top:
        ws = [x[2] for x in g]
        hs = [x[3] for x in g]
        al = [x[4] for x in g]
        print("  %-28s %6d %8.2f %8.2f %8.2f"
              % (str(s), len(g), sum(ws) / len(ws), sum(hs) / len(hs), sum(al) / len(al)))

    # 渲染最高频的 5 个簇
    for rank, (s, g) in enumerate(top[:5], 1):
        # 取该簇里最"居中"的实例, 避免退化
        g2 = sorted(g, key=lambda c: -(c[2] * c[3]))[:1] or g[:1]
        print("\n=== 簇#%d  %s  出现 %d 次 ===" % (rank, s, len(g)))
        for _, pts, wm, hm, arc, n, closed in g2:
            for line in render(pts):
                print("    " + line)
        print("    实例尺寸 %.2f x %.2f mm, %d 段, 弧长 %.2f mm, 闭合=%s"
              % (wm, hm, n, arc, closed))


if __name__ == "__main__":
    main()