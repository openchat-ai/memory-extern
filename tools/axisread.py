"""从轴号气泡读出轴线编号, 建立整套轴网坐标系。

坐标系是整张图的骨架:
  X = 竖轴序号, Y = 横轴序号, Z = 标高
一旦每个构件能挂到 (X, Y, Z), 三维坐标就定了, OCR 只是附属品。
"""
import sys, os, math, json, pickle, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import glyph as G
import synthglyph as S
from shxfont import load_unifont, glyph_polylines
from relations import find_axes, assemble

WORK = '/data/data/com.termux/files/usr/tmp/opencode'
FDIR = os.path.join(WORK, 'cadfont')
R = 32                     # 轴号字高 10~13mm, 16 太挤, 双线会粘连
FONTS = ['simplex.shx', 'tssdeng.shx', 'Tssdeng1.shx', 'romans.shx', 'txt.shx',
         'gbenor.shx', 'gbeitc.shx', 'gothice.shx', 'gothicg.shx', 'italic.shx',
         'complex.shx', 'isocp.shx', 'greekc.shx', 'greeks.shx', 'yjkeng.shx']


def dilate(g, w=1):
    Rr = len(g)
    out = [row[:] for row in g]
    for r in range(Rr):
        for c in range(Rr):
            if g[r][c]:
                for dr in range(-w, w + 1):
                    for dc in range(-w, w + 1):
                        rr, cc = r + dr, c + dc
                        if 0 <= rr < Rr and 0 <= cc < Rr:
                            out[rr][cc] = 1
    return out


def rasterize_hollow(pl, frac=0.17, ratios=(1.0,)):
    """把字形画成**空心双线**再栅格化。

    轴号用的就是这个画法: 每笔是两条平行线, 线距约为字宽的 15~20%。
    之前拿单线字库去比, 两条平行线在 16x16 上并成一条, 于是 A/D 判成 c/O、
    E 判对了只是碰巧 —— 这就是字母轴全错的直接原因。
    """
    pts = [p for poly in pl for p in poly]
    if len(pts) < 2:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    w = max(xs) - min(xs)
    h = max(ys) - min(ys)
    if w < 1e-9 or h < 1e-9:
        return None
    span = max(w, h)
    Rr = 32
    s = (Rr - 2) / span
    ox = (Rr - w * s) / 2 - min(xs) * s
    oy = (Rr - h * s) / 2 + max(ys) * s
    grid = [[0] * Rr for _ in range(Rr)]

    def put(c, r):
        if 0 <= r < Rr and 0 <= c < Rr:
            grid[r][c] = 1

    def seg(x0, y0, x1, y1):
        c = int(x0 * s + ox)
        r = Rr - 1 - int(y0 * s + oy)
        c1 = int(x1 * s + ox)
        r1 = Rr - 1 - int(y1 * s + oy)
        dc, dr = abs(c1 - c), abs(r1 - r)
        sc = 1 if c < c1 else -1
        sr = 1 if r < r1 else -1
        e = dc - dr
        while True:
            put(c, r)
            if c == c1 and r == r1:
                return
            e2 = 2 * e
            if e2 > -dr:
                e -= dr
                c += sc
            if e2 < dc:
                e += dc
                r += sr

    for poly in pl:
        for a, b in zip(poly, poly[1:]):
            dx, dy = b[0] - a[0], b[1] - a[1]
            ln = math.hypot(dx, dy)
            if ln < 1e-9:
                continue
            nx, ny = -dy / ln, dx / ln
            for k in ratios:
                d = span * frac * k
                seg(a[0] + nx * d, a[1] + ny * d, b[0] + nx * d, b[1] + ny * d)
                seg(a[0] - nx * d, a[1] - ny * d, b[0] - nx * d, b[1] - ny * d)
    return grid


def grid2vec(g):
    v = np.zeros(len(g) * len(g), dtype=np.float32)
    Rr = len(g)
    for r in range(Rr):
        b = r * R
        row = g[r]
        for c in range(R):
            if row[c]:
                v[b + c] = 1.0
    return v


def bank():
    out = []
    for f in FONTS:
        p = os.path.join(FDIR, f)
        if not os.path.exists(p):
            continue
        try:
            sf = load_unifont(p)
        except Exception:
            continue
        bk = {}
        for num in sf.shapes:
            pl = glyph_polylines(sf, num)
            if not pl:
                continue
            ch = S.shx_char(num)
            if not ch:
                continue
            vs = []
            oldR = G.RASTER
            G.RASTER = 32
            try:
                g = S.rasterize(pl)                  # 单线
                if g is not None:
                    vs.append(g)
            finally:
                G.RASTER = oldR
            for frac in (0.08, 0.11, 0.14, 0.18):   # 空心双线, 四档线距
                hg = rasterize_hollow(pl, frac)
                if hg is not None:
                    vs.append(hg)
            for v in vs:
                for w in (0, 1):
                    d = dilate(v, w) if w else v
                    if sum(sum(x) for x in d) >= 6:
                        bk.setdefault(ch, []).append(d)
        if bk:
            out.append((f, bk))
    return out


def dists(X, Y):
    a = X.astype(np.float32)
    b = Y.astype(np.float32)
    inter = a @ b.T
    na = a.sum(1)[:, None]
    nb = b.sum(1)[None, :]
    return (na + nb - 2.0 * inter) / np.maximum(na + nb - inter, 1e-6)


def bubble_glyphs(sp, ci, cx, cy, r):
    """圈内的字符路径(排除圆本身和贯穿轴线)"""
    out = []
    for j, q in enumerate(sp):
        if j == ci:
            continue
        mx = sum(p[0] for p in q) / len(q)
        my = sum(p[1] for p in q) / len(q)
        if math.hypot(mx - cx, my - cy) >= r * 0.72:
            continue
        # 贯穿轴线: 两端都伸到圆外。不能用"细长"判定 —— 'D'/'E'/'B' 的竖干
        # 也是细长直线(0.3mm x 12.2mm), 会被误删, 结果字母只剩上下横杠。
        out_of = sum(1 for p in q
                     if math.hypot(p[0] - cx, p[1] - cy) > r * 0.95)
        if out_of >= 2:
            continue
        out.append(j)
    return out


def raster_group(sp, ids, ang=0.0):
    """把一组路径当一个字形栅格化。
    注意 glyph.py 的 bbox/栅格化坐标系是 **pt**(内部乘了 MM=25.4/72)，
    而 sp 里的原始坐标是 mm，这里必须先换算。"""
    MM = 25.4 / 72.0
    xs0 = ys0 = 1e18
    xs1 = ys1 = -1e18
    for i in ids:
        for p in sp[i]:
            xs0 = min(xs0, p[0]); ys0 = min(ys0, p[1])
            xs1 = max(xs1, p[0]); ys1 = max(ys1, p[1])
    cx, cy = (xs0 + xs1) / 2, (ys0 + ys1) / 2
    # 不要按"离中心远近"筛路径: 'D'/'E' 这类字的竖干质心离包围盒中心可达
    # 半个字宽以上, 会被筛掉, 结果只剩上下横杠(2026-10-16 踩过)
    keep = list(ids)
    old = G.RASTER
    G.RASTER = 32
    try:
        return G.raster(sp, keep, cx * MM, cy * MM, ang)
    finally:
        G.RASTER = old


def main():
    sp = pickle.load(open(os.path.join(WORK, 'sp.pkl'), 'rb'))
    ops = pickle.load(open(os.path.join(WORK, 'ops.pkl'), 'rb'))
    bub, vx, vy = find_axes(sp)
    fb = bank()
    print('气泡 %d, 字体 %d' % (len(bub), len(fb)))
    chars = sorted({c for _, bk in fb for c in bk})
    print('候选字符 %d 个' % len(chars))
    res = []
    for ci, cx, cy, r in bub:
        ids = bubble_glyphs(sp, ci, cx, cy, r)
        if not ids:
            res.append((cx, cy, None, 0.0, 0))
            continue
        # 每个字体各投一票(取该字体下最近的字符), 多数胜出。
        # 早期版本把各字体的距离相加再取最小, 等价于"总证据"但看不出分布。
        # 多数投票会被"几何上不匹配的字体"带偏(它们各自投出不同的最近邻)。
        # 真正可靠的信号是**全局最近的那个(字体,字符)**: 形状空间里最接近谁就是谁。
        cands = []
        for ang in (0.0, 90.0, -90.0, 180.0):
            gr = raster_group(sp, ids, ang)
            if gr is None or sum(sum(x) for x in gr) < 3:
                continue
            X = grid2vec(gr)[None, :]
            for f, bk in fb:
                sub = [c for c in chars if c in bk]
                flat, owner = [], []
                for c in sub:
                    for v in bk[c]:
                        flat.append(grid2vec(v))
                        owner.append(c)
                Y = np.array(flat, dtype=np.float32)
                D = dists(X, Y)[0]
                k = int(D.argmin())
                cands.append((float(D[k]), owner[k], f, ang))
        if cands:
            cands.sort()
            d0, ch0, f0, ang = cands[0]
            same = sum(1 for c in cands if c[1] == ch0)
            res.append((cx, cy, ch0, d0, int(round(100.0 * same / len(cands))), ang))
        else:
            res.append((cx, cy, None, 0.0, 0, 0))
    print()
    print('%-9s %-9s %-6s %-8s %-7s %s' % ('圆心x', '圆心y', '轴号', '均距离', '得票', '方向'))
    for cx, cy, ch, d, v, ang in sorted(res, key=lambda z: (round(z[1]), z[0])):
        print('%-9.1f %-9.1f %-6s %-8.3f %-7s %s' % (cx, cy, ch or '?', d, v, ang))
    print()
    # 关系层约束: 同一根轴线上的所有气泡必须读出同一个轴号, 少数服从多数
    print('竖轴 (按约束归并):')
    for v in vx:
        c = collections.Counter()
        dd = collections.defaultdict(list)
        for cx, cy, ch, d, vv2, a in res:
            if abs(cx - v) < 0.6 and ch:
                c[ch] += 1
                dd[ch].append(d)
        if not c:
            print('   x=%-8.1f (无)' % v); continue
        ch, n = c.most_common(1)[0]
        print('   x=%-8.1f -> %r  %d/%d 气泡  平均距离%.3f  (各读数 %s)'
              % (v, ch, n, sum(c.values()), sum(dd[ch]) / len(dd[ch]),
                 dict(c)))
    print('横轴 (按约束归并):')
    for v in vy:
        c = collections.Counter()
        dd = collections.defaultdict(list)
        for cx, cy, ch, d, vv2, a in res:
            if abs(cy - v) < 0.6 and ch:
                c[ch] += 1
                dd[ch].append(d)
        if not c:
            print('   y=%-8.1f (无)' % v); continue
        ch, n = c.most_common(1)[0]
        print('   y=%-8.1f -> %r  %d/%d 气泡  平均距离%.3f  (各读数 %s)'
              % (v, ch, n, sum(c.values()), sum(dd[ch]) / len(dd[ch]),
                 dict(c)))
    json.dump({'%.1f_%.1f' % (a, b): [c, round(float(d), 3), int(v2), int(ang)]
               for a, b, c, d, v2, ang in res},
              open(os.path.join(WORK, 'axis_label.json'), 'w'),
              ensure_ascii=False)
    print()
    print('已存 axis_label.json')


if __name__ == '__main__':
    main()