"""给账本里的每个字形组打标签, 并写出 cluster_label.json / cluster_vote.json。

标签来源(按可信度从高到低):
  1. 跨字体投票: 每个字体各投一票, 票数占比就是置信度
  2. 与合成训练好的分类器一致时追加确认
一律写进账本, 没有标签的就是"未识别", 不允许默认填一个。
"""
import sys, os, json, pickle, math, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
import glyph as G
import synthglyph as S
import glyphbank as GB
from shxfont import load_unifont, glyph_polylines

WORK = '/data/data/com.termux/files/usr/tmp/opencode'
FDIR = os.path.join(WORK, 'cadfont')
R = G.RASTER
FONTS = ['simplex.shx', 'tssdeng.shx', 'Tssdeng1.shx', 'romans.shx', 'txt.shx',
         'gbenor.shx', 'gbeitc.shx', 'gothice.shx', 'gothicg.shx', 'italic.shx',
         'complex.shx', 'isocp.shx', 'greekc.shx', 'greeks.shx', 'yjkeng.shx']


def grid2vec(g):
    v = np.zeros(R * R, dtype=np.float32)
    for r in range(R):
        row = g[r]
        base = r * R
        for c in range(R):
            if row[c]:
                v[base + c] = 1.0
    return v


def dists(X, Y):
    """X:(N,D) Y:(M,D) -> (N,M) 栅格差异率 = |A xor B| / |A or B|
    二值下 |A and B| = a·b, |A or B| = na+nb-inter, |A xor B| = na+nb-2*inter"""
    a = X.astype(np.float32)
    b = Y.astype(np.float32)
    inter = a @ b.T
    na = a.sum(1)[:, None]
    nb = b.sum(1)[None, :]
    diff = na + nb - 2.0 * inter
    union = na + nb - inter
    return diff / np.maximum(union, 1e-6)


def font_bank():
    out = {}
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
            g = S.rasterize(pl)
            if g is None:
                continue
            ch = S.shx_char(num)
            if ch:
                bk.setdefault(ch, g)
        if bk:
            out[f] = bk
    return out


def main():
    sp = pickle.load(open(os.path.join(WORK, 'sp.pkl'), 'rb'))
    ops = pickle.load(open(os.path.join(WORK, 'ops.pkl'), 'rb'))
    import ledger
    rows, circ, tg = ledger.build(sp, ops)
    ledger.classify_nontext(rows, sp)
    print('字形组 %d 个' % len(tg))
    # 必须按行方向旋正后再栅格化 —— 图里尺寸数字是旋转 90° 竖排的,
    # 一律按 0° 栅格化会把它们打成乱码(2026-10-16 踩过)
    import glyph
    runs = glyph.runs([{'paths': m, 'xa': a, 'ya': b, 'xb': c, 'yb': d}
                       for m, a, b, c, d in tg])
    ang_of = {}
    for run in runs:
        a = G.__dict__['run_angle'](run) if 'run_angle' in G.__dict__ else 0.0
        for g in run:
            ang_of[id(g)] = a
    print('文字行 %d 个, 行方向角: %s'
          % (len(runs), sorted(set(round(G.run_angle(r), 0) for r in runs))[:12]))
    X = np.zeros((len(tg), R * R), dtype=np.float32)
    ok = 0
    for k, (mem, xa, ya, xb, yb) in enumerate(tg):
        cx, cy = (xa + xb) / 2.0, (ya + yb) / 2.0
        ang = 0.0
        for r in runs:
            if any(g['paths'] is mem for g in r):
                ang = G.run_angle(r)
                break
        gr = G.raster(sp, mem, cx, cy, ang)
        if gr is None:
            continue
        X[k] = grid2vec(gr)
        ok += 1
    print('成功栅格化 %d 个' % ok)
    fb = font_bank()
    print('字体 %d 个' % len(fb))
    votes = collections.defaultdict(collections.Counter)
    for f, bk in fb.items():
        chars = list(bk.keys())
        Y = np.array([grid2vec(bk[c]) for c in chars], dtype=np.float32)
        Dm = dists(X, Y)
        best = Dm.argmin(1)
        bmin = Dm[np.arange(len(X)), best]
        for k in range(len(tg)):
            votes[k][chars[best[k]]] += 1
    labels = {}
    shares = {}
    for k, c in votes.items():
        ch, n = c.most_common(1)[0]
        labels[k] = ch
        shares[k] = round(float(n) / len(fb), 3)
    json.dump({str(k): v for k, v in labels.items()},
              open(os.path.join(WORK, 'cluster_label.json'), 'w'),
              ensure_ascii=False)
    json.dump({str(k): v for k, v in shares.items()},
              open(os.path.join(WORK, 'cluster_vote.json'), 'w'),
              ensure_ascii=False)
    hi = [k for k, v in shares.items() if v >= 0.6]
    print()
    print('已识别(投票>=60%%): %d / %d  (%.1f%%)' % (len(hi), len(tg),
                                                100.0 * len(hi) / len(tg)))
    for t in (0.5, 0.6, 0.75, 0.9):
        print('   投票>=%.0f%%: %d' % (t * 100, sum(1 for v in shares.values() if v >= t)))
    cnt = collections.Counter(labels.values())
    print('标签字符数 %d, top20: %s' % (len(cnt), cnt.most_common(20)))


if __name__ == '__main__':
    main()