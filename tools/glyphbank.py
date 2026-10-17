"""用矢量字体扩充字形训练集, 训练分类器给图上 142 个聚类打标签。

要点:
1) 合成字形与图上字形在"渲染路径"上不同(字体单位 vs PDF毫米坐标),
   比例会有系统偏差, 所以数据增强里显式加入长宽比抖动、笔画粗细抖动、
   平移抖动, 让分类器对这些不敏感。
2) 标签来自字体本身, 零人工标注噪声 —— 这正是用字体扩充的价值。
"""
import sys, os, pickle, math, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageFont
import glyph as G
from shxfont import load_unifont, glyph_polylines
from synthglyph import rasterize, shx_char, CIRCLED

FDIR = '/data/data/com.termux/files/usr/tmp/opencode/cadfont/'
WORK = '/data/data/com.termux/files/usr/tmp/opencode'
R = G.RASTER
SHX_FONTS = ['simplex.shx', 'tssdeng.shx', 'Tssdeng1.shx', 'romans.shx',
             'txt.shx', 'gbenor.shx', 'gbeitc.shx', 'gothice.shx',
             'gothicg.shx', 'italic.shx', 'complex.shx', 'isocp.shx',
             'greekc.shx', 'greeks.shx']
TTF_FONTS = ['simfang.woff', 'simsun.ttf']

# 结构施工图常用汉字(域词表), 避免生成 2 万个 CJK 全集把手机跑满
DOMAIN_CN = (
    "基础承台垫层防水底板梁板柱墙腋梁后浇带施工缝平剖详图轴线标高"
    "配筋拉结马凳凳筋通长附加箍筋弯钩锚固搭接接头面积配筋率钢筋混凝土"
    "强度等级保护层厚度直径间距根数总长度编号类别规格数量单位备注"
    "尺寸标注总说明索引图纸名称设计审核校对制图比例日期阶段"
    "地下地上室内外总平面竖向定位轴网尺寸洞口墙厚模版模板支架"
    "地下水池消防电梯楼梯栏杆栏杆休息平台女儿墙压顶散水明沟"
    "集水坑电梯井管井检查井化粪池阀门井路灯井雨水口"
    "现浇预埋预留后施工安装拆除支撑拆除改换"
    "第共每层米平方立方米立方毫米"
    "东南西北上下左右中内外前后端侧顶底"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    "ΦφØø±°∠∽≈≤≥×÷‰＃＃＆＠％‰℃"
)


def shift(g, dr, dc):
    out = [[0] * R for _ in range(R)]
    for r in range(R):
        for c in range(R):
            if g[r][c]:
                rr, cc = r + dr, c + dc
                if 0 <= rr < R and 0 <= cc < R:
                    out[rr][cc] = 1
    return out


def dilate(g, w=1):
    if w <= 0:
        return [row[:] for row in g]
    out = [row[:] for row in g]
    for r in range(R):
        for c in range(R):
            if g[r][c]:
                for dr in range(-w, w + 1):
                    for dc in range(-w, w + 1):
                        rr, cc = r + dr, c + dc
                        if 0 <= rr < R and 0 <= cc < R:
                            out[rr][cc] = 1
    return out


def squash(g, fx):
    """长宽比抖动: 横向缩放后重新居中"""
    out = [[0] * R for _ in range(R)]
    for r in range(R):
        for c in range(R):
            if g[r][c]:
                nc = int(round((c - (R - 1) / 2.0) * fx + (R - 1) / 2.0))
                if 0 <= nc < R:
                    out[r][nc] = 1
    return out


def to_vec(g):
    v = np.zeros(R * R, dtype=np.float32)
    for r in range(R):
        for c in range(R):
            if g[r][c]:
                v[r * R + c] = 1.0
    return v


def from_img(a):
    g = [[0] * R for _ in range(R)]
    for r in range(R):
        for c in range(R):
            if a[r, c] > 0.5:
                g[r][c] = 1
    return g


def shx_bank():
    out = []
    for f in SHX_FONTS:
        p = os.path.join(FDIR, f)
        if not os.path.exists(p):
            continue
        try:
            sf = load_unifont(p)
        except Exception:
            continue
        for num in sf.shapes:
            pl = glyph_polylines(sf, num)
            if not pl:
                continue
            g = rasterize(pl)
            if g is None:
                continue
            ch = shx_char(num)
            if ch:
                out.append((ch, f, g))
    return out


def ttf_bank(chars, size=128):
    out = []
    for f in TTF_FONTS:
        p = os.path.join(FDIR, f)
        if not os.path.exists(p):
            continue
        try:
            font = ImageFont.truetype(p, size)
        except Exception:
            continue
        for ch in chars:
            if ch in ' ':
                continue
            try:
                bb = font.getbbox(ch)
                if bb is None:
                    continue
                x0, y0, x1, y1 = bb
                if x1 - x0 < 2 or y1 - y0 < 2:
                    continue
                img = Image.new('L', (x1 - x0, y1 - y0), 0)
                from PIL import ImageDraw
                ImageDraw.Draw(img).text((-x0, -y0), ch, fill=255, font=font)
                a = np.asarray(img, dtype=np.float32) / 255.0
                # 二值化后当折线画: 用轮廓不好取, 直接按笔画粗细压到 1px
                ys, xs = np.nonzero(a > 0.50)
                if len(ys) < 4:
                    continue
                im2 = np.zeros((int(ys.max() - ys.min() + 1),
                                int(xs.max() - xs.min() + 1)), dtype=np.float32)
                im2[ys - ys.min(), xs - xs.min()] = 1.0
                pil = Image.fromarray((im2 * 255).astype(np.uint8))
                s = (R - 2) / max(im2.shape)
                nw = max(4, int(round(im2.shape[1] * s)))
                nh = max(4, int(round(im2.shape[0] * s)))
                pil = pil.resize((nw, nh), Image.BILINEAR)
                a2 = np.asarray(pil, dtype=np.float32) / 255.0
                # 阈值必须够高: 0.30 会把抗锯齿边缘全留下, 汉字直接糊成实心块。
                # 取非零像素中位数的 0.55 倍, 对不同笔画粗细自适应。
                nz = a2[a2 > 0.05]
                thr = max(0.30, float(np.median(nz)) * 0.55) if nz.size else 0.5
                g = [[0] * R for _ in range(R)]
                ox = (R - nw) // 2
                oy = (R - nh) // 2
                for r in range(nh):
                    for c in range(nw):
                        if a2[r, c] > thr and 0 <= oy + r < R and 0 <= ox + c < R:
                            g[oy + r][ox + c] = 1
                if sum(sum(x) for x in g) >= 3:
                    out.append((ch, f, g))
            except Exception:
                continue
    return out


def augment(g, rng):
    fx = 1.0 + rng.uniform(-0.22, 0.22)
    w = rng.choice([0, 0, 0, 1])
    dr = int(rng.integers(-1, 2))
    dc = int(rng.integers(-1, 2))
    return shift(dilate(squash(g, fx), w), dr, dc)


def build(n_aug=4, seed=0):
    rng = np.random.default_rng(seed)
    raw = shx_bank() + ttf_bank(sorted(set(DOMAIN_CN) | set(CIRCLED)))
    chars = sorted(set(c for c, _, _ in raw))
    stoi = {c: i for i, c in enumerate(chars)}
    # 增强策略要温和: 随机 ±22% 长宽比抖动实测把留出准确率从 82.6% 压到 57.7%。
    # 这里用固定的小集合: 原图 + 6 个平移 + 2 档轻微比例(±12%)×(带/不带膨胀)。
    X, y = [], []
    for ch, f, g in raw:
        variants = [g]
        variants += [shift(g, dr, dc) for dr, dc in
                     ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1))]
        for fx in (0.88, 1.12):
            variants.append(squash(g, fx))
            variants.append(dilate(squash(g, fx), 1))
        for a in variants:
            n = sum(sum(x) for x in a)
            if n < 3:
                continue
            X.append(to_vec(a))
            y.append(stoi[ch])
    return np.array(X), np.array(y), chars, len(raw)


if __name__ == '__main__':
    X, y, chars, nraw = build()
    print('原始字形 %d 条, 类别 %d, 增强后样本 %d, 特征维 %d'
          % (nraw, len(chars), X.shape[0], X.shape[1]))
    np.savez(os.path.join(WORK, 'glyphbank.npz'), X=X, y=y,
             chars=np.array(chars, dtype=object), allow_pickle=True)
    cnt = np.bincount(y)
    print('每类样本数: 最小 %d 中位 %d 最大 %d'
          % (cnt.min(), int(np.median(cnt)), cnt.max()))
    print('已存 glyphbank.npz')