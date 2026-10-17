#!/data/data/com.termux/files/usr/bin/python3
"""cluster.py — 对真实图纸的子路径做几何聚类（AGENTS §12: 不打印文字层）

回答一个问题: 11,111 个粗线子路径里, 几何特征能自然分出几簇?
以及: 字符画渲染一小块区域, 让结果可被肉眼核对。
"""
import collections
import math
import re
import sys

M2PT = 72.0 / 25.4


def parse(path):
    """只取几何, 完全不碰文字层。"""
    from pypdf import PdfReader
    r = PdfReader(path)
    s = r.pages[0].get_contents().get_data().decode("latin-1", errors="replace")
    tok = s.replace("\n", " ").split()
    lw, nums, cur = None, [], None
    subpaths, acc = [], []
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
            cur = (nums[-2], nums[-1])
            acc = [cur]
            nums = []
        elif t == "l" and len(nums) >= 2 and acc:
            cur = (nums[-2], nums[-1])
            acc.append(cur)
            nums = []
        else:
            nums = []
    if acc:
        subpaths.append((lw, acc))
    return subpaths


def feat(pts):
    a, b = pts[0], pts[-1]
    L = math.dist(a, b)
    # 直线性: 各点到首尾连线的最大偏移
    if L > 1e-9:
        ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
        dev = max(abs((p[0] - a[0]) * uy - (p[1] - a[1]) * ux) for p in pts)
    else:
        dev = 0.0
    ang = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0])) % 180
    seglen = sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
    return {"L": L, "dev": dev, "ang": ang, "n": len(pts) - 1, "arclen": seglen,
            "straight": dev < 0.02 * max(L, 1e-9), "bbox": L}


def main():
    path = sys.argv[1]
    sp = parse(path)
    thick = [(lw, pts) for lw, pts in sp if lw and lw > 0.5]
    thin = [(lw, pts) for lw, pts in sp if lw and lw <= 0.5]
    print("子路径: 共 %d   粗(w=1.0) %d   细(w=0.12) %d"
          % (len(sp), len(thick), len(thin)))

    F = [feat(p) for _, p in thick]
    print("\n=== 粗线子路径的几何特征 (n=%d) ===" % len(F))
    for key, unit in (("L", "mm"), ("arclen", "mm"), ("n", "段"), ("dev", "mm")):
        v = sorted(f[key] for f in F)
        n = len(v)
        print("  %-7s P10=%8.2f  P50=%8.2f  P90=%8.2f  max=%9.2f  (%s)"
              % (key, v[n // 10], v[n // 2], v[int(n * .9)], v[-1], unit))
    ns = sum(f["straight"] for f in F)
    print("  直线性(偏移<2%%长度): %.1f%% 的子路径是直线" % (100 * ns / len(F)))

    print("\n=== 按 长度×直线性 分桶 (看自然簇) ===")
    lb = [0, .5, 2, 10, 30, 100, 300, 1e9]
    lname = ["<0.5", "0.5-2", "2-10", "10-30", "30-100", "100-300", ">300"]
    tab = collections.Counter()
    for f in F:
        mm = f["L"] / M2PT * 25.4
        k = next(i for i in range(len(lb) - 1) if mm < lb[i + 1])
        tab[(k, f["straight"])] += 1
    print("  %-9s %9s %9s %9s" % ("长度mm", "直线", "曲线", "合计"))
    for k in range(len(lname)):
        a = tab[(k, True)]
        b = tab[(k, False)]
        if a + b:
            print("  %-9s %9d %9d %9d" % (lname[k], a, b, a + b))

    print("\n=== 角度分布(粗线) ===")
    ab = [0, 1, 2, 5, 10, 20, 45, 90, 135, 180]
    ac = collections.Counter()
    for f in F:
        k = next(i for i in range(len(ab) - 1) if f["ang"] < ab[i + 1])
        ac[k] += 1
    for k in range(len(ab) - 1):
        if ac[k]:
            print("  %3d-%3d 度: %6d (%4.1f%%)" % (ab[k], ab[k + 1], ac[k],
                                                  100 * ac[k] / len(F)))

    # 字符画渲染一小块
    allpts = [p for _, pts in sp for p in pts]
    xs = [p[0] for p in allpts]
    ys = [p[1] for p in allpts]
    x0, x1 = min(xs), max(xs)
    y0, y1 = min(ys), max(ys)
    cw = 78
    ch = 30
    cw_mm = (x1 - x0) / cw
    ch_mm = (y1 - y0) / ch
    cx0 = x0 + (x1 - x0) * 0.30
    cy0 = y0 + (y1 - y0) * 0.30
    grid = [[" "] * cw for _ in range(ch)]
    for lw_, pts in sp:
        for i in range(len(pts) - 1):
            (ax, ay), (bx, by) = pts[i], pts[i + 1]
            n = max(1, int(math.hypot(bx - ax, by - ay) / (cw_mm / 2)) + 1)
            for k in range(n + 1):
                x = ax + (bx - ax) * k / n
                y = ay + (by - ay) * k / n
                c = int((x - cx0) / cw_mm)
                r = int((y - cy0) / ch_mm)
                if 0 <= r < ch and 0 <= c < cw:
                    grid[r][c] = "#" if lw_ and lw_ > 0.5 else "."
    print("\n=== 字符画 (左上角 30%% 区域, '#'=粗线 '.'=细线) ===")
    for row in grid:
        print("  |" + "".join(row) + "|")


if __name__ == "__main__":
    main()