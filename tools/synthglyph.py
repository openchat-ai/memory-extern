"""用矢量字体合成字形栅格, 与图上真实聚类对拍。

归一化方式与 tools/glyph.py 的 raster() 完全一致(bbox -> 等比缩放到
RASTER-2 -> 居中 -> Bresenham 描边), 因此合成字形和图上字形在同一空间。
"""
import sys, os, math, json, pickle
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shxfont import load_unifont, glyph_polylines
import glyph as G

FDIR = '/data/data/com.termux/files/usr/tmp/opencode/cadfont/'
WORK = '/data/data/com.termux/files/usr/tmp/opencode'

# AutoCAD SHX 里 33..126 直接就是 ASCII; 其余是符号/希腊/西里尔, 下面按
# 接触表人工确认的少数几个建映射。
# AutoCAD SHX 128..255 特殊码 -> Unicode。
# 未列出的码位用 "\ue000"+码 的私有区占位: 分类器只要求"每个字形有互不相同的
# 标签", 标签叫什么不影响识别, 影响到最后输出文本时才需要补真名。
SHX_EXTRA = {
    0xB2: '∅', 0xB3: '√', 0xB4: '⋅', 0xB5: '≠', 0xB6: '≡',
    0xB7: '≢', 0xB8: '≤', 0xB9: '≥', 0xBA: '∫', 0xBB: '∝',
    0xBC: '∂', 0xBD: '∞', 0xBE: '♂', 0xBF: '♀',
    0xC0: '∠', 0xC1: '∡', 0xC2: '∆', 0xC3: '∇', 0xC4: 'Φ',
    0xC5: 'Ω', 0xC6: 'ℓ', 0xC7: 'ℒ', 0xC8: 'ℛ', 0xC9: '⊥',
    0xCA: '∩', 0xCB: '∪', 0xCC: '⊃', 0xCD: '⊇',
    0xCE: 'Σ', 0xCF: 'Π', 0xD0: 'µ', 0xD1: '⊅',
    0xD2: '⊄', 0xD3: '⊆', 0xD4: '⊇', 0xD5: '⊂',
    0xD6: '⊃', 0xD7: '∪', 0xD8: '∩', 0xD9: '∧',
    0xDA: '∨', 0xDB: '¬', 0xDC: '⇒', 0xDD: '⇔',
    0xDE: '⇑', 0xDF: '⇓', 0xE0: '◊', 0xE1: '□',
    0xE2: '■', 0xE3: '▲', 0xE4: '▼', 0xE5: '◆',
    0xE6: '◊', 0xE7: '°', 0xE8: '′', 0xE9: '″',
    0xEA: '∥', 0xEB: '⊥', 0xEC: '…', 0xED: '‰',
    0xEE: '⊙', 0xEF: '⊗',
    0x1C: '∫', 0x1D: '∬',
}
# 直径符号 %%c 在 AutoCAD 里常走 174/193 两个码位
SHX_EXTRA[174] = 'Φ'
SHX_EXTRA[193] = 'Φ'
SHX_EXTRA[176] = '°'
SHX_EXTRA[177] = '∥'
SHX_EXTRA[178] = '⊥'
SHX_EXTRA[186] = 'Ω'
SHX_EXTRA[189] = '⊙'
SHX_EXTRA[207] = '⊙'

CIRCLED = ('①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳'
           '⓪⒜⒝⒞⒟⒠⒡⒢⒣⒤⒥⒦⒧⒨⒩⒪⒫⒬⒭⒮⒯ⓐⓑⓒⓓⓔⓕⓖⓗⓘⓙⓚⓛⓜⓝⓞⓟⓠⓡⓢⓣⓤⓥⓦⓧⓨⓩ'
           '➀➁➂➃➄➅➆➇➈➉')


# 工程制图里真正会出现的 SHX 特殊符号。希腊/西里尔块和私有区占位符**一律不要**:
# 2026-10-16 实测把它们混进类别后, 合成库留出准确率从 82.6% 掉到 49.2%
# —— 全是图上不可能出现的干扰类, 稀释了判别力。
KEEP_SPECIAL = set('Φ°∥⊥≥≤∞√∆Ω∅≠∫⌒⊤∂∈⋅′″…‰∑Π')


def shx_char(num):
    """返回 Unicode 字符; 不属于工程制图常用集合则返回 None(该字形不入库)。"""
    if 33 <= num <= 126:
        return chr(num)
    ch = SHX_EXTRA.get(num)
    if ch and ch in KEEP_SPECIAL:
        return ch
    return None


def rasterize(polylines):
    """与 glyph.raster 同款的归一化 + Bresenham 描边。"""
    pts = [p for poly in polylines for p in poly]
    if len(pts) < 2:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    w = max(xs) - min(xs)
    h = max(ys) - min(ys)
    if w < 1e-9 or h < 1e-9:
        return None
    # glyph.raster 的 oy 公式假设坐标以 0 为中心(旋转时围绕字形中心),
    # 字体字形的 y 是 0..cap, 必须先中心化, 否则整行 r 为负被裁掉。
    mx = (max(xs) + min(xs)) / 2.0
    my = (max(ys) + min(ys)) / 2.0
    polylines = [[(x - mx, y - my) for x, y in poly] for poly in polylines]
    xs = [x - mx for x in xs]
    ys = [y - my for y in ys]
    R = G.RASTER
    s = (R - 2) / max(w, h)
    ox = (R - w * s) / 2 - min(xs) * s
    oy = (R - h * s) / 2 + max(ys) * s
    grid = [[0] * R for _ in range(R)]

    def put(c, r):
        if 0 <= r < R and 0 <= c < R:
            grid[r][c] = 1

    def seg(x0, y0, x1, y1):
        c = int(x0 * s + ox); r = R - 1 - int(y0 * s + oy)
        c1 = int(x1 * s + ox); r1 = R - 1 - int(y1 * s + oy)
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

    for poly in polylines:
        if len(poly) == 1:
            put(int(poly[0][0] * s + ox), R - 1 - int(poly[0][1] * s + oy))
            continue
        for a, b in zip(poly, poly[1:]):
            seg(a[0], a[1], b[0], b[1])
    return grid


def synth(font_path):
    """-> [(字符, 字体名, grid), ...] 同一字符在不同字体下都要保留"""
    sf = load_unifont(font_path)
    fname = os.path.basename(font_path)
    out = []
    for num in sf.shapes:
        pl = glyph_polylines(sf, num)
        if not pl:
            continue
        g = rasterize(pl)
        if g is None:
            continue
        ch = shx_char(num)
        if ch:
            out.append((ch, fname, g))
    return out


def main():
    sp = pickle.load(open(os.path.join(WORK, 'clusters.pkl'), 'rb'))['clusters']
    R = G.RASTER
    fonts = ['simplex.shx', 'tssdeng.shx', 'Tssdeng1.shx', 'romans.shx',
             'txt.shx', 'gbenor.shx', 'gbeitc.shx', 'gothice.shx',
             'gothicg.shx', 'italic.shx', 'complex.shx', 'isocp.shx',
             'isocp2.shx', 'greekc.shx', 'greeks.shx']
    bank = []
    for f in fonts:
        p = os.path.join(FDIR, f)
        if not os.path.exists(p):
            continue
        try:
            bank.extend(synth(p))
        except Exception as e:
            print('%-14s 跳过: %s' % (f, e))
    chars = set(c for c, _, _ in bank)
    print('合成条目 %d 条, 覆盖字符 %d 个, 字体 %d 个'
          % (len(bank), len(chars), len(fonts)))

    def dist(a, b):
        diff = tot = 0
        for r in range(R):
            ra, rb = a[r], b[r]
            for c in range(R):
                x, y = ra[c], rb[c]
                if x or y:
                    tot += 1
                    if x != y:
                        diff += 1
        return diff / tot if tot else 1.0

    # 全局贪心二分匹配: 独立最近邻会让多个簇抢同一个字符
    pairs = []
    for ci, mem in enumerate(sp):
        cg = mem[0]['grid']
        for ch, f, g in bank:
            pairs.append((dist(cg, g), ci, ch, f))
    pairs.sort(key=lambda z: z[0])
    # 同一字符可以被多个簇使用(不同子像素位置会分成不同簇),
    # 但同一个簇只能配一个字符; 用 (字符,字体) 作为"形"来做全局贪心
    take = {}
    used = set()
    for d, ci, ch, f in pairs:
        if ci in take or (ch, f) in used:
            continue
        take[ci] = (ch, d, f)
        used.add((ch, f))
        if len(take) == len(sp):
            break
    rows = sorted(take.items(), key=lambda z: z[1][1])
    print()
    print('全局贪心匹配后, 距离最小的 30 个簇:')
    print('  簇   成员  字符   距离   字体')
    for ci, (ch, d, f) in rows[:30]:
        print('  %-4d %-5d %-6r %.3f  %s' % (ci, len(sp[ci]), ch, d,
                                             os.path.basename(f)))
    ds = sorted(x[1][1] for x in rows)
    print()
    print('匹配 %d / %d 个簇' % (len(rows), len(sp)))
    print('距离分布: 最小 %.3f  中位 %.3f  最大 %.3f' % (
        ds[0], ds[len(ds) // 2], ds[-1]))
    for t in (0.15, 0.25, 0.35, 0.45, 0.55):
        print('  距离 < %.2f: %d 个' % (t, sum(1 for x in ds if x < t)))
    json.dump({'%d' % ci: [ch, round(d, 4), os.path.basename(f)]
               for ci, (ch, d, f) in take.items()},
              open(os.path.join(WORK, 'synth_match.json'), 'w'),
              ensure_ascii=False)
    print('已存 synth_match.json')


if __name__ == '__main__':
    main()