"""字体体检: 判断某个字体文件和这张 CAD 图的字形是否同源。

用法:
    python3 tools/fontcheck.py <字体文件> [更多字体...]

不靠文件名、不靠"听说是什么字体", 只看字形能不能对上图上 142 个聚类。
输出:
  1) 字形数量 / 可渲染数量
  2) 字形接触表 (cadfont/check_<名>.png) —— 肉眼直接看
  3) 与图上 142 簇的最近距离统计: 最小 / 中位 / <0.3 / <0.5 的个数
  4) 最接近的 20 个簇及其匹配字符
判读:
  出现多个 距离=0.000 的簇  -> 同源, 该字体可以用
  最小距离 >0.3 且没有 0.000 -> 不同源, 换字体
"""
import sys, os, math, pickle
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import glyph as G
import synthglyph as S

WORK = '/data/data/com.termux/files/usr/tmp/opencode'
R = G.RASTER


def dist(a, b):
    d = t = 0
    for r in range(R):
        ra, rb = a[r], b[r]
        for c in range(R):
            x, y = ra[c], rb[c]
            if x or y:
                t += 1
                if x != y:
                    d += 1
    return d / t if t else 1.0


def from_ttf(path, chars):
    out = {}
    try:
        font = ImageFont.truetype(path, 128)
    except Exception as e:
        print('  TTF 打开失败: %s' % e)
        return out
    for ch in chars:
        try:
            bb = font.getbbox(ch)
            x0, y0, x1, y1 = bb
            if x1 - x0 < 2 or y1 - y0 < 2:
                continue
            im = Image.new('L', (x1 - x0 + 4, y1 - y0 + 4), 0)
            ImageDraw.Draw(im).text((2 - x0, 2 - y0), ch, fill=255, font=font)
            a = np.asarray(im, dtype=np.float32) / 255.0
            ys, xs = np.nonzero(a > 0.5)
            if len(ys) < 4:
                continue
            crop = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
            h, w = crop.shape
            s = (R - 2) / max(h, w)
            nw, nh = max(3, int(round(w * s))), max(3, int(round(h * s)))
            pil = Image.fromarray((crop * 255).astype(np.uint8)).resize(
                (nw, nh), Image.BILINEAR)
            a2 = np.asarray(pil, dtype=np.float32) / 255.0
            nz = a2[a2 > 0.05]
            thr = max(0.30, float(np.median(nz)) * 0.55) if nz.size else 0.5
            g = [[0] * R for _ in range(R)]
            ox, oy = (R - nw) // 2, (R - nh) // 2
            for r in range(nh):
                for c in range(nw):
                    if a2[r, c] > thr and 0 <= oy + r < R and 0 <= ox + c < R:
                        g[oy + r][ox + c] = 1
            if sum(sum(x) for x in g) >= 3:
                out[ch] = g
        except Exception:
            continue
    return out


def from_shx(path):
    from shxfont import load_unifont, glyph_polylines
    out = {}
    sf = load_unifont(path)
    for num in sf.shapes:
        pl = glyph_polylines(sf, num)
        if not pl:
            continue
        g = S.rasterize(pl)
        if g is None:
            continue
        ch = S.shx_char(num)
        if ch:
            out.setdefault(ch, g)
    return out


def sheet(bank, path, title):
    ks = sorted(bank.keys())
    if not ks:
        return
    CELL, COLS = 34, 24
    ROWS = (len(ks) + COLS - 1) // COLS
    img = Image.new('L', (COLS * CELL, ROWS * CELL), 255)
    dr = ImageDraw.Draw(img)
    for i, k in enumerate(ks):
        g = bank[k]
        pts = [(r, c) for r in range(R) for c in range(R) if g[r][c]]
        if not pts:
            continue
        rs = [p[0] for p in pts]
        cs = [p[1] for p in pts]
        h = max(rs) - min(rs) + 1
        w = max(cs) - min(cs) + 1
        s = min((CELL - 10) / w, (CELL - 12) / h)
        ox, oy = (i % COLS) * CELL, (i // COLS) * CELL
        for r, c in pts:
            dr.point((ox + 2 + (c - min(cs)) * s, oy + CELL - 12 - (r - min(rs)) * s),
                     fill=0)
        dr.text((ox + 1, oy + CELL - 10), k if len(k) == 1 else '#',
                fill=150)
    img.save(path)


def check(path):
    name = os.path.basename(path)
    print('=' * 64)
    print('字体: %s' % path)
    ext = os.path.splitext(path)[1].lower()
    if ext == '.shx':
        bank = from_shx(path)
    else:
        chars = ('0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
                 'abcdefghijklmnopqrstuvwxyz()[]{}+-*/=@#$%&<>'
                 'Φ°∥⊥≥≤.,;:!?\'"_①②③④⑤⑥⑦⑧⑨⑩')
        bank = from_ttf(path, chars)
    print('  字形数 %d' % len(bank))
    if not bank:
        print('  无法提取字形, 换格式或换文件')
        return
    out = os.path.join(WORK, 'cadfont', 'check_%s.png' % name.replace('.', '_'))
    sheet(bank, out, name)
    print('  字形表 -> %s' % out)
    cl = pickle.load(open(os.path.join(WORK, 'clusters.pkl'), 'rb'))['clusters']
    rows = []
    for ci, mem in enumerate(cl):
        g = mem[0]['grid']
        ch, d = min(((ch, dist(g, gg)) for ch, gg in bank.items()), key=lambda z: z[1])
        rows.append((d, ci, len(mem), ch))
    rows.sort()
    ds = [r[0] for r in rows]
    n0 = sum(1 for x in ds if x < 0.0005)
    n3 = sum(1 for x in ds if x < 0.3)
    n5 = sum(1 for x in ds if x < 0.5)
    print('  与图上 142 簇: 最小 %.3f  中位 %.3f   距离=0: %d   <0.3: %d   <0.5: %d'
          % (ds[0], ds[len(ds) // 2], n0, n3, n5))
    print('  最接近的 20 个簇:')
    for d, ci, n, ch in rows[:20]:
        print('    簇%-4d 成员%-4d -> %-4r  距离 %.3f' % (ci, n, ch, d))
    if n0 >= 3:
        print('  >>> 判定: 同源(有多个精确匹配), 这个字体可以用')
    elif ds[0] < 0.2:
        print('  >>> 判定: 可能同源但渲染路径有差异, 可作辅助')
    else:
        print('  >>> 判定: 不同源(最好也只有 %.3f), 换字体' % ds[0])


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for p in sys.argv[1:]:
        check(p)