#!/data/data/com.termux/files/usr/bin/python3
"""scan.py — 批量渲染文字串成可看的对照图(宽度受控), 供逐张扫描.

v2: 按宽度分桶, 每张图宽度<=1900px, 行高按串的实际高度,
    并在左侧留编号槽(用短横线数量表示序号), 便于定位.
"""
import collections
import math
import sys

sys.path.insert(0, "/data/data/com.termux/files/home/sram/tools")
from topng import load, write_png          # noqa: E402

PT = 72.0 / 25.4      # mm -> pt
MM = 25.4 / 72.0      # pt -> mm
MAXW = 1850


def components(sp):
    EPS = 0.15 * MM
    par = {}

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a
    for q in sp:
        if len(q) < 2:
            continue
        k0 = (round(q[0][0] / EPS), round(q[0][1] / EPS))
        k1 = (round(q[-1][0] / EPS), round(q[-1][1] / EPS))
        par.setdefault(k0, k0)
        par.setdefault(k1, k1)
        ra, rb = find(k0), find(k1)
        if ra != rb:
            par[ra] = rb
    comp = collections.defaultdict(list)
    for i, q in enumerate(sp):
        if len(q) < 2:
            continue
        comp[find((round(q[0][0] / EPS), round(q[0][1] / EPS)))].append(i)
    out = []
    for root, idxs in comp.items():
        P = [p for i in idxs for p in sp[i]]
        cx = [p[0] for p in P]
        cy = [p[1] for p in P]
        w = (max(cx) - min(cx)) * MM
        h = (max(cy) - min(cy)) * MM
        if 0.9 <= h <= 5.5 and 0.3 <= w <= 6.0:
            out.append((min(cx), max(cx), (min(cy) + max(cy)) / 2, h))
    return out


def runs_of(items):
    items.sort(key=lambda c: c[2])
    rows, cur, cy = [], [items[0]], items[0][2]
    for c in items[1:]:
        if abs(c[2] - cy) < 0.5 * PT:
            cur.append(c)
        else:
            rows.append(cur)
            cur = [c]
            cy = c[2]
    rows.append(cur)
    runs = []
    for r in rows:
        r.sort(key=lambda c: c[0])
        run = [r[0]]
        for a, b in zip(r, r[1:]):
            if (b[0] - a[1]) * MM < 2.2:
                run.append(b)
            else:
                if len(run) >= 5:
                    runs.append(run)
                run = [b]
        if len(run) >= 5:
            runs.append(run)
    return runs


def draw(sp, run, dpi):
    X0 = min(c[0] for c in run) - 0.6 * PT
    X1 = max(c[1] for c in run) + 0.6 * PT
    hmax = max(c[3] for c in run) + 1.2
    aw = X1 - X0
    ah = hmax * PT
    wi = max(1, int(aw * dpi / 72.0))
    hi = max(1, int(ah * dpi / 72.0))
    buf = bytearray([255]) * (wi * hi)
    sx, sy = wi / aw, hi / ah
    YC = run[0][2]

    def px_of(x, y):
        return (int((x - X0) * sx), int((YC + ah / 2 - y) * sy))

    for q in sp:
        qx = [p[0] for p in q]
        if max(qx) < X0 or min(qx) > X1:
            continue
        for i in range(len(q) - 1):
            A, B = q[i], q[i + 1]
            c, r = px_of(A[0], A[1])
            c1, r1 = px_of(B[0], B[1])
            dc, dr = abs(c1 - c), abs(r1 - r)
            sc = 1 if c < c1 else -1
            sr = 1 if r < r1 else -1
            e = dc - dr
            while True:
                if 0 <= r < hi and 0 <= c < wi:
                    buf[r * wi + c] = 0
                if c == c1 and r == r1:
                    break
                e2 = 2 * e
                if e2 > -dr:
                    e -= dr
                    c += sc
                if e2 < dc:
                    e += dc
                    r += sr
    return wi, hi, buf


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    sp = load(src)
    runs = runs_of(components(sp))
    # 分桶: 保证单张宽度 <= MAXW
    buckets, cur, cw = [], [], 0
    for r in sorted(runs, key=lambda r: max(c[1] for c in r) - min(c[0] for c in r)):
        wpx = int((max(c[1] for c in r) - min(c[0] for c in r) + 1.2 * PT) * 1100 / 72.0)
        if cw + wpx > MAXW and cur:
            buckets.append(cur)
            cur, cw = [], 0
        cur.append(r)
        cw += wpx
    if cur:
        buckets.append(cur)
    print("共 %d 串, 分成 %d 张对照图" % (len(runs), len(buckets)))
    n = 0
    for bi, b in enumerate(buckets, 1):
        tiles = []
        for r in b:
            dpi = 1100
            w = int((max(c[1] for c in r) - min(c[0] for c in r) + 1.2 * PT) * dpi / 72.0)
            while w > 1800:
                dpi = int(dpi * 1850 / w)
                w = int((max(c[1] for c in r) - min(c[0] for c in r) + 1.2 * PT) * dpi / 72.0)
            tiles.append(draw(sp, r, dpi))
        W = max(t[0] for t in tiles)
        H = sum(t[1] + 6 for t in tiles)
        img = bytearray([255]) * (W * H)
        y = 0
        for w, h, buf in tiles:
            for rr in range(h):
                img[(y + rr) * W:(y + rr) * W + w] = buf
            y += h + 6
        p = "%s/sheet%02d.png" % (outdir, bi)
        write_png(p, W, H, img)
        print("  sheet%02d.png %dx%d  (%d 串)" % (bi, W, H, len(b)))
        n += 1
        if n >= 14:
            print("  ...共 %d 张, 只输出前 14 张" % len(buckets))
            break


if __name__ == "__main__":
    main()
