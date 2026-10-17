#!/data/data/com.termux/files/usr/bin/python3
"""findrow.py — 找出图纸里的"文字行"并直接渲染出来.

文字在图纸上表现为: 一行内多个小笔画, y 接近, x 等间距。
填充线/剖面线不会成行。所以先按行聚合, 再 ASCII 渲染整行。
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
    lw, nums, subpaths, acc = None, [], [], []
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


def main():
    sp = parse(sys.argv[1])
    items = []
    for lw, pts in sp:
        if len(pts) < 2:
            continue
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        w = (max(xs) - min(xs)) / M2PT * 25.4
        h = (max(ys) - min(ys)) / M2PT * 25.4
        if 0.2 <= max(w, h) <= 10.0:
            items.append({"lw": lw, "pts": pts, "cx": sum(xs) / len(xs),
                          "cy": sum(ys) / len(ys), "w": w, "h": h})
    print("小尺度子路径 %d 个" % len(items))

    # 按 y 行聚合
    rows = collections.defaultdict(list)
    for it in items:
        rows[round(it["cy"] / 1.0)].append(it)     # 1pt 一行

    # 找"行内 x 递增且间距均匀"的组
    cands = []
    for yk, group in rows.items():
        if len(group) < 4:
            continue
        group.sort(key=lambda g: g["cx"])
        run = [group[0]]
        for a, b in zip(group, group[1:]):
            gap = (b["cx"] - a["cx"]) / M2PT * 25.4
            if 0.3 <= gap <= 12.0:
                run.append(b)
            else:
                if len(run) >= 5:
                    cands.append((yk, list(run)))
                run = [b]
        if len(run) >= 5:
            cands.append((yk, run))
    cands.sort(key=lambda c: -len(c[1]))
    print("找到成行的组: %d, 最长一行 %d 个笔画" % (len(cands),
                                              max(len(c[1]) for c in cands) if cands else 0))

    for rank, (yk_, run) in enumerate(cands[:6], 1):
        xs0 = min(min(p[0] for p in g["pts"]) for g in run)
        xs1 = max(max(p[0] for p in g["pts"]) for g in run)
        ys0 = min(min(p[1] for p in g["pts"]) for g in run)
        ys1 = max(max(p[1] for p in g["pts"]) for g in run)
        span = (xs1 - xs0) / M2PT * 25.4
        print("\n=== 第%d行: %d 个笔画, 宽 %.1f mm, 高 %.1f mm, 粗线%d 细线%d ==="
              % (rank, len(run), span, (ys1 - ys0) / M2PT * 25.4,
                 sum(1 for g in run if g["lw"] and g["lw"] > 0.5),
                 sum(1 for g in run if g["lw"] and g["lw"] <= 0.5)))
        # 渲染
        CW = 100
        CH = 16
        grid = [[" "] * CW for _ in range(CH)]
        sx = (xs1 - xs0) or 1e-9
        sy = (ys1 - ys0) or 1e-9
        for g in run:
            ch = "#" if g["lw"] and g["lw"] > 0.5 else "."
            for i in range(len(g["pts"]) - 1):
                (ax, ay), (bx, by) = g["pts"][i], g["pts"][i + 1]
                n = max(1, int(math.hypot(bx - ax, by - ay) / (sx / CW)) + 1)
                for k in range(n + 1):
                    x = ax + (bx - ax) * k / n
                    yy = ay + (by - ay) * k / n
                    c = int((x - xs0) / sx * (CW - 1))
                    r = CH - 1 - int((yy - ys0) / sy * (CH - 1))
                    if 0 <= r < CH and 0 <= c < CW:
                        grid[r][c] = ch
        for row in grid:
            print("   |" + "".join(row) + "|")


if __name__ == "__main__":
    main()