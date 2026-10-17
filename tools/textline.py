#!/data/data/com.termux/files/usr/bin/python3
"""textline.py — 找横向成行的小字(钢筋标注字号), 输出 PNG 供核对."""
import math
import sys

sys.path.insert(0, "/data/data/com.termux/files/home/sram/tools")
from topng import load, render, write_png   # noqa: E402

PT = 25.4 / 72.0


def main():
    src = sys.argv[1]
    outdir = sys.argv[2]
    sp = load(src)
    boxes = []
    for q in sp:
        xs = [p[0] for p in q]
        ys = [p[1] for p in q]
        w = (max(xs) - min(xs)) * PT
        h = (max(ys) - min(ys)) * PT
        if 0.8 <= max(w, h) <= 6.0:
            boxes.append((min(xs), max(xs), min(ys), max(ys)))
    print("小尺度子路径 %d 个" % len(boxes))
    # 按 y 绝对分箱(mm), 再校验行高
    bins = {}
    for b in boxes:
        yc = (b[2] + b[3]) / 2 * PT
        bins.setdefault(round(yc / 0.8), []).append(b)
    rows = []
    for k, v in bins.items():
        ylo = min(b[2] for b in v) * PT
        yhi = max(b[3] for b in v) * PT
        if yhi - ylo <= 4.0:          # 行高必须在 4mm 内, 否则是竖向串联
            rows.append(v)
    # 行内按 x 找连续段 (间隙 < 4mm)
    runs = []
    for row in rows:
        row.sort(key=lambda b: b[0])
        run = [row[0]]
        for a, b in zip(row, row[1:]):
            if (b[0] - a[1]) * PT < 4.0:
                run.append(b)
            else:
                if len(run) >= 4:
                    runs.append(run)
                run = [b]
        if len(run) >= 4:
            runs.append(run)
    # 排除底部 14% 图签带
    ys_all = [p[1] for q in sp for p in q]
    ymax = max(ys_all)
    runs = [r for r in runs if min(b[2] for b in r) > ymax * 0.14]
    runs.sort(key=lambda r: -len(r))
    print("候选行 %d, 最长 %d 个笔画" % (len(runs), max(len(r) for r in runs) if runs else 0))
    for i, r in enumerate(runs[:5], 1):
        ax = min(b[0] for b in r) - 2
        ay = min(b[2] for b in r) - 2
        aw = (max(b[1] for b in r) - min(b[0] for b in r)) + 4
        ah = (max(b[3] for b in r) - min(b[2] for b in r)) + 4
        w, h, px = render(sp, ax, ay, aw, ah, 600)
        write_png("%s/line%d.png" % (outdir, i), w, h, px)
        print("line%d.png  %d 个笔画, 宽 %.1fmm 高 %.1fmm, %dx%d px"
              % (i, len(r), aw * PT, ah * PT, w, h))


if __name__ == "__main__":
    main()
