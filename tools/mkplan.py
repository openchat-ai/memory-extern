#!/data/data/com.termux/files/usr/bin/python3
"""mkplan.py — 手工构造一个"伪矢量 CAD 图纸"PDF, 全部用贝塞尔曲线.

模仿 CAD 导出的三个特点:
  1. 所有几何都是三次贝塞尔 (c 算子), 直线也用贝塞尔近似
  2. 按图层给不同线宽: 墙 0.50mm / 标注 0.13mm / 引线 0.18mm
  3. 文字转轮廓 (用线段拼的假字形)

目的: 看导出后还能拿回多少结构, 特别是**线宽是否保留**.
"""
import zlib

W, H = 841, 1189          # A0 mm
M2PT = 72.0 / 25.4        # mm -> pt

LW_WALL = 0.50
LW_DIM = 0.13
LW_LEAD = 0.18
LW_FRAME = 0.70


def bez_line(p0, p1, bulge=0.02):
    """把直线表示成一段贝塞尔 (CAD 导出常见做法)."""
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = (x1 - x0) * bulge, (y1 - y0) * bulge
    return (f"{x0:.3f} {y0:.3f} m "
            f"{x0+dx:.3f} {y0+dy:.3f} {x1-dx:.3f} {y1-dy:.3f} {x1:.3f} {y1:.3f} c")


def bez_circle(cx, cy, r, k=0.5523):
    """圆用 4 段贝塞尔逼近 (PDF 里没有真正的圆)."""
    o = r * k
    s = []
    s.append(f"{cx-r:.3f} {cy:.3f} m")
    s.append(f"{cx-r:.3f} {cy+o:.3f} {cx-o:.3f} {cy+r:.3f} {cx:.3f} {cy+r:.3f} c")
    s.append(f"{cx+o:.3f} {cy+r:.3f} {cx+r:.3f} {cy+o:.3f} {cx+r:.3f} {cy:.3f} c")
    s.append(f"{cx+r:.3f} {cy-o:.3f} {cx+o:.3f} {cy-r:.3f} {cx:.3f} {cy-r:.3f} c")
    s.append(f"{cx-o:.3f} {cy-r:.3f} {cx-r:.3f} {cy-o:.3f} {cx-r:.3f} {cy:.3f} c")
    return " ".join(s)


def polyline(pts, lw, color=(0, 0, 0)):
    body = " ".join(bez_line(pts[i], pts[i + 1]) for i in range(len(pts) - 1))
    return (f"q {color[0]} {color[1]} {color[2]} RG {color[0]} {color[1]} {color[2]} rg "
            f"{lw*M2PT:.3f} w 1 J {body} S Q")


def circle(cx, cy, r, lw, color=(0, 0, 0)):
    return (f"q {color[0]} {color[1]} {color[2]} RG {lw*M2PT:.3f} w 1 J "
            f"{bez_circle(cx, cy, r)} S Q")


def fake_text(x, y, s, lw=0.2, color=(0, 0, 0)):
    """用短线拼出"字形轮廓", 模拟文字转曲. 只为占位, 不求可读."""
    out, cx = [], x
    for ch in s:
        if ch == " ":
            cx += 3.0
            continue
        box = [(cx, y), (cx + 2.2, y), (cx + 2.2, y + 3.5), (cx, y + 3.5)]
        out.append(polyline(box + [box[0]], lw, color))
        # 加一横, 看起来像字而不是方框
        out.append(polyline([(cx + 0.4, y + 1.8), (cx + 1.8, y + 1.8)], lw, color))
        cx += 3.2
    return "".join(out)


def build_content():
    P = []
    # 图框 (最粗)
    P.append(polyline([(20, 20), (W-20, 20), (W-20, H-20), (20, H-20), (20, 20)], LW_FRAME))
    # 房间墙: 4 段, 中间开个门洞 -> 拆成 5 段
    x0, y0, x1, y1 = 100.0, 200.0, 600.0, 500.0
    P.append(polyline([(x0, y0), (x1, y0)], LW_WALL))
    P.append(polyline([(x1, y0), (x1, y1)], LW_WALL))
    P.append(polyline([(x1, y1), (x0, y1)], LW_WALL))
    P.append(polyline([(x0, y1), (x0, y0)], LW_WALL))
    # 内隔墙带门洞
    P.append(polyline([(x0, 350), (300, 350)], LW_WALL))
    P.append(polyline([(340, 350), (400, 350)], LW_WALL))
    # 标注线 (最细) + 尺寸界线
    P.append(polyline([(x0, y0-40), (x1, y0-40)], LW_DIM))
    P.append(polyline([(x0, y0), (x0, y0-45)], LW_DIM))
    P.append(polyline([(x1, y0), (x1, y0-45)], LW_DIM))
    P.append(fake_text(330, y0-38, "5000"))
    # 竖向标注
    P.append(polyline([(x1+40, y0), (x1+40, y1)], LW_DIM))
    P.append(fake_text(x1+42, (y0+y1)/2, "3000"))
    # 引线 (中粗) 带折点
    P.append(polyline([(250, 350), (280, 420), (330, 450)], LW_LEAD))
    P.append(circle(250, 350, 1.2, LW_LEAD))
    P.append(fake_text(332, 451, "Phi8@200"))
    # 剖切符号
    P.append(polyline([(150, 650), (200, 650)], LW_LEAD))
    P.append(polyline([(170, 650), (170, 690)], LW_LEAD))
    P.append(fake_text(172, 692, "1-1"))
    # 签名栏
    P.append(polyline([(W-260, 60), (W-40, 60), (W-40, 140), (W-260, 140), (W-260, 60)], LW_FRAME))
    P.append(polyline([(W-260, 100), (W-40, 100)], LW_FRAME))
    P.append(fake_text(W-250, 110, "A0 1:100"))
    P.append(fake_text(W-250, 70, "2026-10-15"))
    return "\n".join(P)


def make_pdf(path):
    content = build_content()
    comp = zlib.compress(content.encode("latin-1"))
    objs = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 %.2f %.2f] "
         "/Contents 4 0 R /Resources << >> >>" % (W, H)).encode(),
        b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(comp) + comp + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offs = []
    for i, body in enumerate(objs, 1):
        offs.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for o in offs:
        out += b"%010d 00000 n \n" % o
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    with open(path, "wb") as f:
        f.write(bytes(out))
    return path


if __name__ == "__main__":
    import sys
    p = sys.argv[1] if len(sys.argv) > 1 else "/data/data/com.termux/files/usr/tmp/opencode/plan.pdf"
    make_pdf(p)
    print("已生成", p)
