#!/data/data/com.termux/files/usr/bin/python3
"""mkfont.py — 把从 PDF 提取的钢筋符号做成 TTF 字体字形.

码位按 sjqy.ttf / TSSDENG.TTF 的行业约定:
  U+E000 = Ⅰ级 (HPB300)
  U+E001 = Ⅱ级 (HRB335)  ← 本图提取的就是这个
  U+E002 = Ⅲ级 (HRB400)
AutoCAD 里对应 %%130 / %%131 / %%132

输入: 提取到的 4 条路径(两竖 + 圆 + 底横), SVG 坐标系(y 向下, 1000 宽)
输出: rebar.ttf, 可直接当字符使用
"""
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen

UPEM = 1000
STEM = 55          # 笔画宽度(千分单位), 接近常规字体字干
HALF = STEM // 2


def rect(x0, x1, y0, y1):
    """矩形 -> 闭合轮廓(字体坐标 y 向上)."""
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def flip(pts):
    return [(x, UPEM - y) for x, y in pts]


# --- 从 PDF 提取的原始数据(SVG 坐标, y 向下) ---
V1 = [(350, 33), (350, 750)]
V2 = [(133, 33), (133, 750)]
BASE = [(33, 750), (450, 750)]
CIRCLE = [(183.33, 182.92), (100, 216.25), (50, 266.25), (33.33, 299.58),
          (0, 332.92), (0, 416.25), (33.33, 449.58), (50, 482.92),
          (100, 516.25), (183.33, 549.58), (283.33, 549.58), (366.67, 516.25),
          (416.67, 482.92), (450, 449.58), (466.67, 416.25), (466.67, 332.92),
          (450, 299.58), (416.67, 266.25), (366.67, 216.25), (283.33, 182.92)]


def build(path):
    fb = FontBuilder(UPEM, isTTF=True)
    fb.setupGlyphOrder([".notdef", "rebar_hrb335"])
    fb.setupCharacterMap({0xE001: "rebar_hrb335"})   # Ⅱ级, 按 sjqy.ttf 约定

    pen = TTGlyphPen(None)
    for line in (V1, V2, BASE):
        (x0, y0), (x1, y1) = line
        if y0 == y1:                      # 横
            pen.moveTo((min(x0, x1), y0))
            pen.lineTo((min(x0, x1) + STEM, y0))
            pen.lineTo((min(x0, x1) + STEM, y0 + STEM))
            pen.lineTo((min(x0, x1), y0 + STEM))
            pen.closePath()
        else:                              # 竖
            pen.moveTo((x0 - HALF, y0))
            pen.lineTo((x0 + HALF, y0))
            pen.lineTo((x0 + HALF, y1))
            pen.lineTo((x0 - HALF, y1))
            pen.closePath()
    c = flip(CIRCLE)
    pen.moveTo(c[0])
    for p in c[1:]:
        pen.lineTo(p)
    pen.closePath()

    glyphs = {".notdef": TTGlyphPen(None).glyph(), "rebar_hrb335": pen.glyph()}
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({".notdef": (600, 0), "rebar_hrb335": (620, 40)})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "RebarSymbols", "styleName": "Regular",
                       "fullName": "RebarSymbols HRB335",
                       "psName": "RebarSymbols-Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800,
                usWinDescent=200)
    fb.setupPost()
    fb.save(path)
    print("已生成 %s" % path)
    print("  字符: U+E001 (私用区) = Ⅱ级钢筋, 名字 rebar_hrb335")
    print("  CAD 对应: %%131   Word: 输入 E001 选中按 Alt+X")
    print("  轮廓: 2 竖 + 圆(20边形) + 底横, 共 4 条闭合轮廓")
    print("  em=%d, 字干宽=%d" % (UPEM, STEM))


if __name__ == "__main__":
    import sys
    build(sys.argv[1] if len(sys.argv) > 1 else "rebar.ttf")
