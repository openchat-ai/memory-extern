"""glyph.py — 切出图纸中的文字字形，旋正归一化后聚类。

不识别内容，只做三件事：切字形 -> 旋正 -> 聚类。
聚类结果再人工/模型命名，即可得到字形到字符的映射。

用法:  python3 tools/glyph.py <paths.pkl>
"""
import math
import pickle
import sys

MM = 25.4 / 72.0
GAP = 0.35           # 字形合并间隙 mm
MIN_SZ = 0.20        # 最小字形尺寸 mm
MAX_SZ = 4.00        # 最大字形尺寸 mm
RUN_GAP = 1.20       # 同一行相邻字形中心距上限 mm
SPLIT_GAP = 0.12     # 判定为"两个字粘连"所需的 x 空隙 mm
CELL = 0.5           # 空间网格 mm
RASTER = 16          # 归一化位图边长


def split_fused(paths, bb, xa, ya, xb, yb, sp):
    """按"无路径跨越的 x 空隙"劈开粘连字形。

    不能只按宽高比判断：ΦⅢ级符号宽高比 0.65、@ 0.70，与粘连的 "20"(1.15)
    量级接近。真正的区别是——粘连的两个字之间存在一段没有任何路径覆盖的 x，
    而单个字形的各部件在 x 上互相重叠。
    """
    w, h = xb - xa, yb - ya
    if h < 0.4 or w / h < 0.60:
        return None
    iv = []
    for i in paths:
        q = sp[i]
        qx = [p[0] * MM for p in q]
        iv.append((min(qx), max(qx)))
    iv.sort()
    cuts, cur_start, cur_end = [], iv[0][0], iv[0][1]
    for s, e in iv[1:]:
        if s - cur_end >= SPLIT_GAP:
            cuts.append((cur_start, cur_end))
            cur_start, cur_end = s, e
        else:
            cur_end = max(cur_end, e)
    cuts.append((cur_start, cur_end))
    if len(cuts) < 2:
        return None
    out = []
    for s, e in cuts:
        sel = [i for i in paths
               if s - SPLIT_GAP <= min(p[0] * MM for p in sp[i]) and max(p[0] * MM for p in sp[i]) <= e + SPLIT_GAP]
        if not sel:
            continue
        px = [p[0] * MM for i in sel for p in sp[i]]
        py = [p[1] * MM for i in sel for p in sp[i]]
        pw, ph = max(px) - min(px), max(py) - min(py)
        if pw < 0.15 or ph < 0.4 or ph / pw > 8:
            continue
        out.append({'xa': min(px), 'ya': min(py), 'xb': max(px), 'yb': max(py),
                    'paths': sel})
    return out if len(out) >= 2 else None


def bbox(q):
    xs = [p[0] for p in q]
    ys = [p[1] for p in q]
    return min(xs) * MM, min(ys) * MM, max(xs) * MM, max(ys) * MM


def bbox_of(run):
    """整行的外框 + 字高 + 主色。"""
    if not run:
        return None
    xa = min(g['xa'] for g in run)
    ya = min(g['ya'] for g in run)
    xb = max(g['xb'] for g in run)
    yb = max(g['yb'] for g in run)
    hs = [g['yb'] - g['ya'] for g in run]
    hs.sort()
    col = None
    if 'color' in run[0]:
        tally = {}
        for g in run:
            if g['color'] is not None:
                tally[g['color']] = tally.get(g['color'], 0) + 1
        if tally:
            col = max(tally.items(), key=lambda kv: kv[1])[0]
    return {'xa': xa, 'ya': ya, 'xb': xb, 'yb': yb,
            'w': xb - xa, 'h': yb - ya,
            'h_med': hs[len(hs) // 2], 'color': col, 'n': len(run)}


def load_colors(path):
    """路径下标 -> 颜色。解析失败时返回空表，不影响几何流程。"""
    try:
        from topng import load_color
    except ImportError:
        return {}
    try:
        sc = load_color(path)
    except Exception:
        return {}
    return {i: col for i, (col, _) in enumerate(sc)}


def cluster_paths(sp, colors=None):
    """把路径按空间邻近合并成字形候选。返回 [paths...]。"""
    cand = []
    for i, q in enumerate(sp):
        xa, ya, xb, yb = bbox(q)
        w, h = xb - xa, yb - ya
        if not (MIN_SZ <= max(w, h) <= MAX_SZ):
            continue
        cand.append((i, xa, ya, xb, yb))
    grid = {}
    for n, (i, xa, ya, xb, yb) in enumerate(cand):
        for gx in range(int(xa / CELL), int(xb / CELL) + 1):
            for gy in range(int(ya / CELL), int(yb / CELL) + 1):
                grid.setdefault((gx, gy), []).append(n)
    par = list(range(len(cand)))

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a

    for members in grid.values():
        for a in members:
            for b in members:
                ra, rb = find(a), find(b)
                if ra != rb:
                    par[ra] = rb
    groups = {}
    for n in range(len(cand)):
        groups.setdefault(find(n), []).append(n)
    out = []
    queue = []
    for g in groups.values():
        xa = min(cand[i][1] for i in g)
        ya = min(cand[i][2] for i in g)
        xb = max(cand[i][3] for i in g)
        yb = max(cand[i][4] for i in g)
        if xb - xa > MAX_SZ or yb - ya > MAX_SZ or xb - xa < 0.15 or yb - ya < 0.4:
            continue
        queue.append([cand[i][0] for i in g])
    nsplit = 0
    while queue:
        paths = queue.pop()
        px = [p[0] * MM for i in paths for p in sp[i]]
        py = [p[1] * MM for i in paths for p in sp[i]]
        xa, ya, xb, yb = min(px), min(py), max(px), max(py)
        parts = split_fused(paths, None, xa, ya, xb, yb, sp)
        if parts:
            nsplit += len(parts)
            queue.extend(p['paths'] for p in parts)
        else:
            g = {'xa': xa, 'ya': ya, 'xb': xb, 'yb': yb, 'paths': paths}
            if colors is not None:
                tally = {}
                for i in paths:
                    c = colors.get(i)
                    if c is not None:
                        tally[c] = tally.get(c, 0) + 1
                g['color'] = max(tally.items(), key=lambda kv: kv[1])[0] if tally else None
            out.append(g)
    print('  粘连劈开 %d 块' % nsplit)
    return out


def runs(glyphs):
    """把字形按基线聚成文字行。返回 [[glyph...], ...]"""
    rows = {}
    for g in glyphs:
        rows.setdefault(round((g['ya'] + g['yb']) / 2 / 0.5), []).append(g)
    out = []
    for key in sorted(rows):
        lst = sorted(rows[key], key=lambda g: g['xa'])
        cur = [lst[0]]
        for g in lst[1:]:
            p = cur[-1]
            gap = (g['xa'] - p['xb']) / 2
            if gap <= RUN_GAP:
                cur.append(g)
            else:
                out.append(cur)
                cur = [g]
        out.append(cur)
    return [r for r in out if len(r) >= 3]


def run_angle(run):
    """用首尾字形中心连线估基线倾角。"""
    if len(run) < 2:
        return 0.0
    ax = (run[0]['xa'] + run[0]['xb']) / 2
    ay = (run[0]['ya'] + run[0]['yb']) / 2
    bx = (run[-1]['xa'] + run[-1]['xb']) / 2
    by = (run[-1]['ya'] + run[-1]['yb']) / 2
    if abs(bx - ax) < 1e-6:
        return 0.0
    return math.degrees(math.atan2(by - ay, bx - ax))


def raster(sp, paths, cx, cy, ang):
    """旋正后把字形描边栅格化为 RASTER x RASTER 的 0/1 特征。

    必须连线描边：数字是折线轮廓，只点顶点会在网格上断成散点。
    """
    ca, sa = math.cos(math.radians(-ang)), math.sin(math.radians(-ang))

    def xf(p):
        dx, dy = p[0] * MM - cx, p[1] * MM - cy
        return dx * ca - dy * sa, dx * sa + dy * ca

    allp = []
    for i in paths:
        allp.extend(xf(p) for p in sp[i])
    if not allp:
        return None
    w = max(p[0] for p in allp) - min(p[0] for p in allp)
    h = max(p[1] for p in allp) - min(p[1] for p in allp)
    if w < 1e-6 or h < 1e-6:
        return None
    s = (RASTER - 2) / max(w, h)
    ox = (RASTER - w * s) / 2 - min(p[0] for p in allp) * s
    oy = (RASTER - h * s) / 2 + max(p[1] for p in allp) * s
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

    for i in paths:
        pts = [xf(p) for p in sp[i]]
        if len(pts) == 1:
            put(int(pts[0][0] * s + ox), RASTER - 1 - int(pts[0][1] * s + oy))
            continue
        for a, b in zip(pts, pts[1:]):
            seg(a[0], a[1], b[0], b[1])
    return grid


def dist(a, b):
    """栅格差异率。"""
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


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else 'sp.pkl'
    sp = pickle.load(open(path, 'rb'))
    glyphs = cluster_paths(sp)
    print('字形候选 %d 个' % len(glyphs))
    rr = runs(glyphs)
    print('成行(>=3字) %d 行, 共 %d 字' % (len(rr), sum(len(r) for r in rr)))
    feats = []
    for run in rr:
        ang = run_angle(run)
        for g in run:
            cx = (g['xa'] + g['xb']) / 2
            cy = (g['ya'] + g['yb']) / 2
            grid = raster(sp, g['paths'], cx, cy, ang)
            if grid:
                feats.append({'grid': grid,
                              'w': g['xb'] - g['xa'], 'h': g['yb'] - g['ya'],
                              'ang': ang, 'x': cx, 'y': cy, 'run': id(run)})
    print('可栅格化 %d 字' % len(feats))
    clusters = []
    for f in feats:
        for cl in clusters:
            if dist(f['grid'], cl[0]['grid']) < 0.14:
                cl.append(f)
                break
        else:
            clusters.append([f])
    print('一次聚类 %d 簇' % len(clusters))
    # 二次合并：实测同类距离 0.14~0.54、异类 0.83~0.97，中间有干净空档，
    # 故用 0.60 卡在空档中间，把同字符的不同实例并到一起。
    merged = True
    while merged and len(clusters) > 1:
        merged = False
        out = []
        used = [False] * len(clusters)
        for a in range(len(clusters)):
            if used[a]:
                continue
            grp = list(clusters[a])
            used[a] = True
            for b in range(a + 1, len(clusters)):
                if used[b]:
                    continue
                if dist(clusters[b][0]['grid'], grp[0]['grid']) < 0.60:
                    grp.extend(clusters[b])
                    used[b] = True
                    merged = True
            out.append(grp)
        clusters = out
    print('二次合并后 %d 簇' % len(clusters))
    sizes = sorted((len(c) for c in clusters), reverse=True)
    print('  前20:', sizes[:20])
    print('  单样本簇:', sum(1 for s in sizes if s == 1))
    pickle.dump({'clusters': [[{k: v for k, v in f.items()} for f in c]
                              for c in clusters]}, open('clusters.pkl', 'wb'))
    print('已存 clusters.pkl')


if __name__ == '__main__':
    main()
