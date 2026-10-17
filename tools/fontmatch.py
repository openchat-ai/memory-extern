"""fontmatch.py — 用真实 CAD 字体给图纸字形簇定标签。

图纸文字虽已转曲，但字形来源是已知的 CAD 字体。把候选字体的字形渲染成
与聚类相同的归一化位图，再做距离比对，就能确定性地给簇命名，
不需要人工逐个辨认。

用法:  python3 tools/fontmatch.py <clusters.pkl> <字体目录>
"""
import math
import os
import pickle
import sys

RASTER = 16


def raster(verts):
    """折线 -> RASTER x RASTER 的 0/1 位图。必须先居中，否则包围盒会被
    离群点撑大，字形缩到网格一角，看起来像"只渲染了一半"。"""
    pts = [(float(v[0]), float(v[1])) for v in verts]
    if len(pts) < 2:
        return None
    cx = (min(p[0] for p in pts) + max(p[0] for p in pts)) / 2
    cy = (min(p[1] for p in pts) + max(p[1] for p in pts)) / 2
    pts = [(p[0] - cx, p[1] - cy) for p in pts]
    w = max(p[0] for p in pts) - min(p[0] for p in pts)
    h = max(p[1] for p in pts) - min(p[1] for p in pts)
    if w < 1e-9 or h < 1e-9:
        return None
    s = (RASTER - 2) / max(w, h)
    ox = (RASTER - w * s) / 2 - min(p[0] for p in pts) * s
    oy = (RASTER - h * s) / 2 + max(p[1] for p in pts) * s
    grid = [[0] * RASTER for _ in range(RASTER)]

    def put(c, r):
        if 0 <= r < RASTER and 0 <= c < RASTER:
            grid[r][c] = 1

    def seg(x0, y0, x1, y1):
        c, r = int(x0 * s + ox), RASTER - 1 - int(y0 * s + oy)
        c1, r1 = int(x1 * s + ox), RASTER - 1 - int(y1 * s + oy)
        dc, dr = abs(c1 - c), abs(r1 - r)
        sc = 1 if c < c1 else -1
        sr = 1 if r < r1 else -1
        e = dc - dr
        while True:
            put(c, r)
            if c == c1 and r == r1:
                break
            e2 = 2 * e
            if e2 > -dr:
                e -= dr
                c += sc
            if e2 < dc:
                e += dc
                r += sr

    for a, b in zip(pts, pts[1:]):
        seg(a[0], a[1], b[0], b[1])
    return grid


def dist(a, b):
    diff = tot = 0
    for r in range(RASTER):
        ra, rb = a[r], b[r]
        for c in range(RASTER):
            x, y = ra[c], rb[c]
            if x or y:
                tot += 1
                if x != y:
                    diff += 1
    return diff / tot if tot else 1.0


def load_templates(fontdir):
    """渲染候选字体的可打印字符，返回 [(字符, 字体, 位图), ...]。"""
    from ezdxf.fonts import shapefile as S
    out = []
    codes = ([c for c in range(0x21, 0x7f)] +
             [c for c in range(0xa1, 0x100)] +
             list(range(0x100, 0x160)))
    for fn in sorted(os.listdir(fontdir)):
        if not fn.lower().endswith('.shx'):
            continue
        try:
            sf = S.shx_load(open(os.path.join(fontdir, fn), 'rb').read())
        except Exception as e:
            print('  跳过 %s: %s' % (fn, type(e).__name__))
            continue
        n = 0
        for code in codes:
            if code > 255:
                break
            try:
                s = sf.find(bytes([code]))
            except Exception:
                s = None
            if s is None:
                continue
            try:
                p = S.render_shapes([s.number], sf.get_codes, False)
                g = raster(p.flattening(0.004))
            except Exception:
                continue
            if g is None:
                continue
            ink = sum(sum(row) for row in g)
            if ink < 4:          # 空白/近乎空白的字形会匹配一切，必须剔除
                continue
            out.append((code, chr(code) if 32 <= code < 127 else '?', fn, g))
            n += 1
        print('  %-14s %d 个字形可用' % (fn, n))
    return out


def main():
    clusters = pickle.load(open(sys.argv[1], 'rb'))['clusters']
    tpl = load_templates(sys.argv[2])
    print('模板总数 %d' % len(tpl))
    print()
    print('%-6s %-6s %-14s %-6s %-8s %s' %
          ('簇', '样本', '最佳匹配', '字体', '距离', '次优(距离)'))
    best_labels = {}
    for ci, c in enumerate(clusters):
        g = c[0]['grid']
        ranked = sorted(((dist(g, t[3]), t[0], t[1], t[2]) for t in tpl))
        d0, code0, ch0, fn0 = ranked[0]
        d1 = ranked[1][0]
        best_labels[ci] = (ch0, fn0, d0)
        alt = '' if len(ranked) < 2 else '%r(%s) %.3f' % (ranked[1][1], ranked[1][2][:6], d1)
        print('%-6d %-6d %-14r %-6s %-8.3f %s' %
              (ci, len(c), ch0, fn0.replace('.shx', ''), d0, alt))
    pickle.dump(best_labels, open('fontmatch.pkl', 'wb'))


if __name__ == '__main__':
    main()
