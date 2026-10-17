"""关系层: 把路径级账本连成结构, 并用结构反过来校验。

核心思想(2026-10-16 用户提出): 账本不该是平表, 因为图里存在强拓扑关系 ——
  轴号气泡 → 必须连着轴网线
  轴网线  → 必须带着尺寸标注(尺寸线+界线+数字)
  尺寸数字 → 必须等于几何量出来的距离

于是这些关系本身就是**校验器**:
  连不上轴网线  -> 账有漏
  轴线上没数字  -> 账有漏
  数字与几何不符 -> 数字识别错 或 几何提取错, 两者至少一个错
"""
import sys, os, json, pickle, math, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import glyph as G

WORK = '/data/data/com.termux/files/usr/tmp/opencode'


def bbox(q):
    xs = [p[0] for p in q]
    ys = [p[1] for p in q]
    return min(xs), min(ys), max(xs), max(ys)


def line_kind(q, tol=1.2):
    """返回 ('h'|'v'|'d', 长度) 或 None。tol 是垂直度容差(度)。"""
    x0, y0, x1, y1 = bbox(q)
    w, h = x1 - x0, y1 - y0
    if max(w, h) < 3.0:
        return None
    if h < tol and w > 0:
        return ('h', w)
    if w < tol and h > 0:
        return ('v', h)
    return None


def find_axes(sp, rmin=10.5, rmax=12.0):
    """轴号气泡 -> 轴网坐标。气泡沿图框周边, 但它标出的是整张轴网的行列号。"""
    bub = []
    for i, q in enumerate(sp):
        n = len(q)
        if n < 16 or n > 64:
            continue
        cx = sum(p[0] for p in q) / n
        cy = sum(p[1] for p in q) / n
        rs = [math.hypot(p[0] - cx, p[1] - cy) for p in q]
        r = sum(rs) / n
        if not (rmin < r < rmax):
            continue
        if sum((x - r) ** 2 for x in rs) / n > (0.10 * r) ** 2:
            continue
        angs = sorted(math.atan2(p[1] - cy, p[0] - cx) for p in q)
        gaps = [angs[k + 1] - angs[k] for k in range(len(angs) - 1)]
        gaps.append(angs[0] + 2 * math.pi - angs[-1])
        if max(gaps) > math.pi * 0.6:
            continue
        bub.append((i, cx, cy, r))
    vx = sorted(set(round(c[1], 1) for c in bub))
    vy = sorted(set(round(c[2], 1) for c in bub))
    return bub, vx, vy


def assemble(sp, coord, kind, band=2.0, maxgap=8.0):
    """把共线的短段(点划线)拼成一条虚拟轴线。
    返回 [(起点, 终点, 覆盖长度, 段数)]"""
    segs = []
    for i, q in enumerate(sp):
        if len(q) > 3:
            continue
        x0, y0, x1, y1 = bbox(q)
        if kind == 'h':
            if y1 - y0 > band or x1 - x0 < 2.0:
                continue
            if abs((y0 + y1) / 2 - coord) > band:
                continue
            segs.append((min(x0, x1), max(x0, x1), i))
        else:
            if x1 - x0 > band or y1 - y0 < 2.0:
                continue
            if abs((x0 + x1) / 2 - coord) > band:
                continue
            segs.append((min(y0, y1), max(y0, y1), i))
    segs.sort()
    chains = []
    cur = []
    for a, b, i in segs:
        if cur and a - cur[-1][1] > maxgap:
            chains.append(cur)
            cur = []
        cur.append((a, b, i))
    if cur:
        chains.append(cur)
    out = []
    for c in chains:
        lo = min(x[0] for x in c)
        hi = max(x[1] for x in c)
        cov = sum(x[1] - x[0] for x in c)
        out.append((lo, hi, cov, len(c), [x[2] for x in c]))
    out.sort()
    return out


def axis_lines(sp, vx, vy):
    out = []
    for v in vy:
        for lo, hi, cov, n, ids in assemble(sp, v, 'h'):
            if hi - lo > 50:
                out.append(('h', ids, v, lo, hi, cov, n))
    for v in vx:
        for lo, hi, cov, n, ids in assemble(sp, v, 'v'):
            if hi - lo > 50:
                out.append(('v', ids, v, lo, hi, cov, n))
    return out


def text_runs(sp, ops, max_sz=16.0):
    """所有字形组 + 其标签。返回 [(groups...)] 见 labelall。"""
    import glyph
    import ledger
    old = glyph.MAX_SZ
    glyph.MAX_SZ = max_sz
    try:
        Gs = glyph.cluster_paths(sp)
    finally:
        glyph.MAX_SZ = old
    return Gs


def main():
    sp = pickle.load(open(os.path.join(WORK, 'sp.pkl'), 'rb'))
    ops = pickle.load(open(os.path.join(WORK, 'ops.pkl'), 'rb'))
    labels = json.load(open(os.path.join(WORK, 'cluster_label.json')))
    shares = json.load(open(os.path.join(WORK, 'cluster_vote.json')))

    bub, vx, vy = find_axes(sp)
    print('轴号气泡 %d 个' % len(bub))
    print('竖轴坐标 x (%d 条): %s' % (len(vx), vx))
    print('横轴坐标 y (%d 条): %s' % (len(vy), vy))
    print('竖向柱距: %s' % [round(vx[i + 1] - vx[i], 1) for i in range(len(vx) - 1)])
    print('横向柱距: %s' % [round(vy[i + 1] - vy[i], 1) for i in range(len(vy) - 1)])

    al = axis_lines(sp, vx, vy)
    hv = [a for a in al if a[0] == 'h']
    vv = [a for a in al if a[0] == 'v']
    print()
    print('轴网线(点划线拼接后): 横 %d 段, 竖 %d 段' % (len(hv), len(vv)))
    print('  横轴线所在 y: %s' % sorted(set(round(a[2], 1) for a in hv)))
    print('  竖轴线所在 x: %s' % sorted(set(round(a[2], 1) for a in vv)))

    Gs = text_runs(sp, ops)
    print()
    print('=== 每条轴网线上的文字(沿整条线找, 不是只看那一段) ===')
    seen = set()
    report = []
    for kind, ids, c, lo, hi, cov, nseg in al:
        near = []
        for k, g in enumerate(Gs):
            gx = (g['xa'] + g['xb']) / 2
            gy = (g['ya'] + g['yb']) / 2
            if kind == 'h':
                along, across = gx, gy
            else:
                along, across = gy, gx
            if not (lo - 60 <= along <= hi + 60):
                continue
            if abs(across - c) > 40:
                continue
            near.append((along, k))
        near.sort()
        txt = ''.join(labels.get(str(k), '?') for _, k in near)
        good = sum(1 for _, k in near if shares.get(str(k), 0) >= 0.6)
        report.append((kind, round(c, 1), round(hi - lo), len(near), good, txt))
        seen.add((kind, round(c, 1)))
    print('%-4s %-9s %-8s %-7s %-7s %s' % ('向', '坐标', '跨度', '字数', '可信', '文本'))
    for kind, c, L, n, g, txt in sorted(report, key=lambda z: (z[0], z[1])):
        print('%-4s %-9s %-8.0f %-7d %-7d %s' % (kind, c, L, n, g, txt[:70]))
    print()
    empt = [k for k in seen if not any(
        r[0] == k[0] and abs(r[1] - k[1]) < 0.2 and r[3] > 0 for r in report)]
    print('轴网线 %d 条, 其中完全没有文字的 %d 条' % (len(seen), len(empt)))
    if empt:
        print('  ', sorted(empt))


if __name__ == "__main__":
    main()
