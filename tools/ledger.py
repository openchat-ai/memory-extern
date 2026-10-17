"""路径级账本 + 对账。

动机(2026-10-16): 今晚连续三次静默丢数据 ——
  1. render() 里路径坐标(mm)与窗口参数(pt)单位不一致, 差 2.83 倍
  2. f*/B* 填充算子完全没实现, 9,604 条路径画不出来
  3. glyph.cluster_paths 的 MAX_SZ=4.0mm 把 8~13mm 的轴号字符全滤掉
三次都没有任何报错, 都是靠人眼偶然发现。所以这里立规矩:
  **每一条路径都必须有归属和状态, 对不上账就不算做完。**

账本每行 = 一条路径, 字段:
  id          路径序号
  op          绘制算子 S / f* / B*
  npts        点数
  bbox        包围盒 mm (x0,y0,x1,y1)
  length      折线总长 mm, 闭合路径另给面积 mm^2
  category    归属: axis_circle / axis_label / text / line_geom / unclassified
  cluster     text 类对应的字形簇号, 否则空
  ocr         OCR 状态: recognized / unlabeled / n_a
  source      标签来源: font / tesseract / crnn / manual / none
  conf        置信度 0~1, 无则空
"""
import sys, os, math, json, pickle, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np

WORK = '/data/data/com.termux/files/usr/tmp/opencode'


def plen(q):
    return sum(math.hypot(q[i + 1][0] - q[i][0], q[i + 1][1] - q[i][1])
               for i in range(len(q) - 1))


def parea(q):
    a = 0.0
    n = len(q)
    for i in range(n):
        x0, y0 = q[i]
        x1, y1 = q[(i + 1) % n]
        a += x0 * y1 - x1 * y0
    return abs(a) / 2.0


def bbox(q):
    xs = [p[0] for p in q]
    ys = [p[1] for p in q]
    return min(xs), min(ys), max(xs), max(ys)


def find_circles(sp, rmin=10.5, rmax=12.0):
    """返回 [(path_id, cx, cy, r)] —— 轴号气泡。"""
    out = []
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
        out.append((i, cx, cy, r))
    return out


def build_text_groups(sp, ops, max_sz=16.0):
    """字形候选分组。直接复用 tools/glyph.py 的聚类(含粘连劈分), 只放宽上限,
    让 8~13mm 的轴号字符也能进来; 不自己重写一套。"""
    import glyph
    old = glyph.MAX_SZ
    glyph.MAX_SZ = max_sz
    try:
        G = glyph.cluster_paths(sp)
    finally:
        glyph.MAX_SZ = old
    return [(g['paths'], g['xa'], g['ya'], g['xb'], g['yb']) for g in G]


def classify_nontext(rows, sp):
    """给未归类路径再分档 —— 账本不允许有"说不清是什么"的大类。"""
    by = {r['id']: r for r in rows}
    frags = 0
    for r in rows:
        if r['category'] != 'unclassified':
            continue
        w, h, L = r['w'], r['h'], r['len']
        if max(w, h) < 1.0:
            r['category'] = 'frag_dot'
        elif max(w, h) < 3.0:
            r['category'] = 'frag_small'
        elif L > 300 and (w > 200 or h > 200):
            r['category'] = 'page_border'
        elif L > 50 and (w < 0.6 or h < 0.6):
            r['category'] = 'axis_or_dim_line'
        elif L > 20 and (w < 1.5 or h < 1.5):
            r['category'] = 'thin_line'
        elif max(w, h) > 60:
            r['category'] = 'long_polyline'
        else:
            r['category'] = 'geom_other'
    return by


def attach_ocr(rows, tg, labels, votes, vote_th=0.6):
    """给每个文字字形组填 OCR 状态与证据来源。

    **三态, 不能只两态**: 只要有标签就算"已识别"会制造假信心 ——
    投票会给每一个组都发一个标签, 哪怕是垃圾。必须按置信度分档。
      recognized     投票>=vote_th, 可直接用
      low_confidence 有标签但投票不足, 需复核
      unlabeled      没有标签
    """
    nrec = nunl = nlow = 0
    for k, (mem, xa, ya, xb, yb) in enumerate(tg):
        lab = labels.get(k)
        share = votes.get(k, 0.0)
        if not lab:
            st, src, cf = 'unlabeled', 'none', None
        elif share >= vote_th:
            st, src, cf = 'recognized', 'vote', round(float(share), 3)
        else:
            st, src, cf = 'low_confidence', 'vote', round(float(share), 3)
        for i in mem:
            r = _IDX[i]
            r['ocr'] = st
            r['source'] = src
            r['conf'] = cf
        if st == 'recognized':
            nrec += 1
        elif st == 'low_confidence':
            nlow += 1
        else:
            nunl += 1
    return nrec, nunl, nlow


_IDX = {}


def byid_get(i):
    return _IDX[i]


def build(sp, ops):
    rows = []
    circ = find_circles(sp)
    circ_ids = {c[0]: c for c in circ}
    # 轴号字符: 落在气泡内、非圆、非贯穿轴线
    axis_label = set()
    for i, cx, cy, r in circ:
        for j, q in enumerate(sp):
            if j == i:
                continue
            mx = sum(p[0] for p in q) / len(q)
            my = sum(p[1] for p in q) / len(q)
            if math.hypot(mx - cx, my - cy) >= r * 0.78:
                continue
            w, h = bbox(q)[2] - bbox(q)[0], bbox(q)[3] - bbox(q)[1]
            if len(q) == 2 and (w < 0.4 or h < 0.4) and max(w, h) > r * 0.5:
                continue                      # 贯穿的轴线
            axis_label.add(j)
    # 正文字形
    tg = build_text_groups(sp, ops)
    text_of = {}
    for k, (mem, xa, ya, xb, yb) in enumerate(tg):
        for i in mem:
            text_of[i] = k
    axis_set = set(circ_ids) | axis_label
    for i, q in enumerate(sp):
        x0, y0, x1, y1 = bbox(q)
        closed = (len(q) > 2 and
                  abs(q[0][0] - q[-1][0]) < 1e-9 and abs(q[0][1] - q[-1][1]) < 1e-9)
        if i in circ_ids:
            cat = 'axis_circle'
        elif i in axis_label:
            cat = 'axis_label'
        elif i in text_of:
            cat = 'text'
        else:
            cat = 'unclassified'
        _IDX[i] = None
        rows.append({
            'id': i, 'op': ops[i], 'npts': len(q),
            'bbox': [round(x0, 2), round(y0, 2), round(x1, 2), round(y1, 2)],
            'w': round(x1 - x0, 2), 'h': round(y1 - y0, 2),
            'len': round(plen(q), 2),
            'area': round(parea(q), 2) if closed else None,
            'category': cat,
            'cluster': text_of.get(i, ''),
            'ocr': 'n_a', 'source': 'none', 'conf': None,
        })
    for r in rows:
        _IDX[r['id']] = r
    return rows, circ, tg


def reconcile(rows):
    n = len(rows)
    c = collections.Counter(r['category'] for r in rows)
    o = collections.Counter(r['op'] for r in rows)
    ok = n == sum(c.values())
    lines = []
    lines.append('=' * 62)
    lines.append('对账: 路径总数 %d' % n)
    lines.append('  归属合计 %d  ->  %s' % (sum(c.values()), '平' if ok else '不平!'))
    for k, v in c.most_common():
        lines.append('    %-14s %7d  (%5.1f%%)' % (k, v, 100.0 * v / n))
    lines.append('  算子分布: %s' % dict(o))
    unc = [r for r in rows if r['category'] == 'unclassified']
    lines.append('')
    lines.append('未归类 %d 条 —— 这些不是文字, 但必须能解释' % len(unc))
    sz = collections.Counter()
    for r in unc:
        sz[(r['w'] > 300, r['h'] > 300, r['len'] > 200)] += 1
    lines.append('  尺寸分档(是否超长线): %s' % dict(sz))
    return '\n'.join(lines), c


if __name__ == '__main__':
    sp = pickle.load(open(os.path.join(WORK, 'sp.pkl'), 'rb'))
    ops = pickle.load(open(os.path.join(WORK, 'ops.pkl'), 'rb'))
    rows, circ, tg = build(sp, ops)
    classify_nontext(rows, sp)
    labels = json.load(open(os.path.join(WORK, 'cluster_label.json'))) \
        if os.path.exists(os.path.join(WORK, 'cluster_label.json')) else {}
    votes = json.load(open(os.path.join(WORK, 'cluster_vote.json'))) \
        if os.path.exists(os.path.join(WORK, 'cluster_vote.json')) else {}
    nrec, nunl, nlow = attach_ocr(rows, tg,
                                 {int(k): v for k, v in labels.items()},
                                 {int(k): v for k, v in votes.items()})
    txt, c = reconcile(rows)
    print('OCR 三态 (共 %d 个字形组):' % len(tg))
    print('   recognized     %5d  (%5.1f%%)  投票>=60%%, 可直接用'
          % (nrec, 100.0 * nrec / max(len(tg), 1)))
    print('   low_confidence %5d  (%5.1f%%)  有标签但投票不足, 需复核'
          % (nlow, 100.0 * nlow / max(len(tg), 1)))
    print('   unlabeled      %5d  (%5.1f%%)'
          % (nunl, 100.0 * nunl / max(len(tg), 1)))
    print()
    print(txt)
    print()
    print('轴号气泡 %d 个, 轴号字形路径 %d 条, 正文字形组 %d 个'
          % (len(circ), sum(1 for r in rows if r['category'] == 'axis_label'),
             len(tg)))
    json.dump(rows, open(os.path.join(WORK, 'ledger.json'), 'w'),
              ensure_ascii=False)
    print('账本已存 ledger.json (%d 行)' % len(rows))