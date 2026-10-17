#!/data/data/com.termux/files/usr/bin/python3
"""topng.py — 把图纸的一个区域渲染成高分辨率 PNG, 供人工核对 (AGENTS §12: 只输出几何)."""
import math, struct, sys, zlib


def load_color(path):
    """与 load() 同构，但额外记录每条路径的填充/描边颜色。

    返回 [(color, subpath), ...]，color 为
        ('RGB', r, g, b) | ('GRAY', v) | ('CMYK', c, m, y, k)
      | ('SEP', 名称, tint) | None（未显式设置，用默认值）
    """
    from pypdf import PdfReader
    r = PdfReader(path)
    s = r.pages[0].get_contents().get_data().decode("latin-1", errors="replace")
    tok = s.replace("\n", " ").split()
    out, acc, nums = [], [], []
    PAINT = {"S", "f", "f*", "F", "B", "B*", "b", "b*", "n"}
    FILLONLY = {"f", "f*", "F", "B", "B*", "b", "b*"}
    stack, ctm = [], (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    fcs = scs = bcs = "DeviceGray"
    fill = stroke = None

    def xf(x, y):
        a, b, c, d, e, f = ctm
        return (a * x + c * y + e, b * x + d * y + f)

    def emit():
        nonlocal acc
        if acc:
            out.append((fill if (tok_last in FILLONLY) else stroke, acc))
        acc = []

    tok_last = None
    for t in tok:
        try:
            nums.append(float(t))
            continue
        except ValueError:
            pass
        tok_last = t
        if t == "q":
            stack.append((ctm, fcs, scs, bcs, fill, stroke))
        elif t == "Q":
            if stack:
                ctm, fcs, scs, bcs, fill, stroke = stack.pop()
        elif t == "cm" and len(nums) >= 6:
            a, b, c, d, e, f = nums[-6:]
            A, B, C, D, E, F = ctm
            ctm = (a * A + b * C, a * B + b * D,
                   c * A + d * C, c * B + d * D,
                   e * A + f * C + E, e * B + f * D + F)
            nums = []
        elif t == "cs" and nums:
            fcs = scs = bcs = str(nums[-1]).lstrip("/")
            nums = []
        elif t == "CS" and nums:
            bcs = str(nums[-1]).lstrip("/")
            nums = []
        elif t == "g" and nums:
            fill = ("GRAY", nums[-1])
            nums = []
        elif t == "G" and nums:
            stroke = ("GRAY", nums[-1])
            nums = []
        elif t == "rg" and len(nums) >= 3:
            fill = ("RGB", nums[-3], nums[-2], nums[-1])
            nums = []
        elif t == "RG" and len(nums) >= 3:
            stroke = ("RGB", nums[-3], nums[-2], nums[-1])
            nums = []
        elif t == "k" and len(nums) >= 4:
            fill = ("CMYK",) + tuple(nums[-4:])
            nums = []
        elif t == "K" and len(nums) >= 4:
            stroke = ("CMYK",) + tuple(nums[-4:])
            nums = []
        elif t in ("sc", "scn", "SC", "SCN"):
            n = list(nums)
            nums = []
            if not n:
                continue
            cs = fcs if t in ("sc", "scn") else bcs
            if cs == "DeviceRGB" and len(n) >= 3:
                col = ("RGB", n[-3], n[-2], n[-1])
            elif cs == "DeviceCMYK" and len(n) >= 4:
                col = ("CMYK",) + tuple(n[-4:])
            elif cs == "DeviceGray" and len(n) >= 1:
                col = ("GRAY", n[-1])
            else:
                col = ("SEP", cs, tuple(n))       # 专色：名称+色调
            if t in ("sc", "scn"):
                fill = col
            else:
                stroke = col
        elif t == "m" and len(nums) >= 2:
            emit()
            acc = [xf(nums[-2], nums[-1])]
            nums = []
        elif t == "l" and len(nums) >= 2 and acc:
            acc.append(xf(nums[-2], nums[-1]))
            nums = []
        elif t == "h" and acc:
            if acc[-1] != acc[0]:
                acc.append(acc[0])
            nums = []
        elif t in PAINT:
            emit()
            nums = []
        else:
            nums = []
    emit()
    return out


def load(path):
    """兼容入口: 只返回点列。带算子请用 load_ops()。"""
    return load_ops(path)[0]


def load_ops(path):
    """返回 (点列, 算子)。算子取值 'S' / 'f*' / 'B*' / 'n'。

    正确实现: 维护图形状态栈, 累积 CTM, 每个点按当前 CTM 变换到用户空间。

    旧实现套了一个固定的全局变换(cm 全部相同), 导致部分区块镜像/错位。
    本版额外保留每条路径的绘制算子 —— 2026-10-16 发现之前 9,604 条
    f*/B* 填充路径全部被当成描边丢失, 轴号气泡因此"消失"。
    """
    from pypdf import PdfReader
    r = PdfReader(path)
    s = r.pages[0].get_contents().get_data().decode("latin-1", errors="replace")
    tok = s.replace("\n", " ").split()
    sp, ops, acc, nums = [], [], [], []
    PAINT = {"S", "f", "f*", "F", "B", "B*", "b", "b*", "n"}
    FILL = {"f", "f*", "F", "B", "B*", "b", "b*"}
    STROKE = {"S", "B", "B*", "b", "b*"}
    stack = []
    ctm = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)

    def xf(x, y):
        a, b, c, d, e, f = ctm
        return (a * x + c * y + e, b * x + d * y + f)

    def emit():
        if acc:
            sp.append(acc)
            ops.append(cur_op)

    cur_op = "S"
    for t in tok:
        try:
            nums.append(float(t))
            continue
        except ValueError:
            pass
        if t == "q":
            stack.append(ctm)
        elif t == "Q":
            if stack:
                ctm = stack.pop()
        elif t == "cm" and len(nums) >= 6:
            n = nums[-6:]
            a, b, c, d, e, f = n
            A, B, C, D, E, F = ctm
            ctm = (a * A + b * C, a * B + b * D,
                   c * A + d * C, c * B + d * D,
                   e * A + f * C + E, e * B + f * D + F)
            nums = []
        elif t == "m" and len(nums) >= 2:
            emit()
            acc = [xf(nums[-2], nums[-1])]
            nums = []
        elif t == "l" and len(nums) >= 2 and acc:
            acc.append(xf(nums[-2], nums[-1]))
            nums = []
        elif t == "h" and acc:
            if acc[-1] != acc[0]:
                acc.append(acc[0])
            nums = []
        elif t in PAINT:
            cur_op = t
            emit()
            acc = []
            nums = []
        else:
            nums = []
    emit()
    return sp, ops


def write_png(path, w, h, px):
    raw = b"".join(b"\x00" + bytes(px[r*w:(r+1)*w]) for r in range(h))
    def ch(t, d):
        c = t + d
        return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)))
        f.write(ch(b"IDAT", zlib.compress(raw, 9)))
        f.write(ch(b"IEND", b""))


def render(sp, ax, ay, aw, ah, dpi, ops=None):
    """ax/ay/aw/ah 单位 pt; sp 里的路径坐标单位 mm(内部换算).
    ops 可选, 长度与 sp 相同; 含 'f'/'B' 的路径按**偶奇规则扫描线填充**,
    含 'S'/'B' 的路径描边。不给 ops 时全部按描边处理(旧行为)。
    线段极短(0.025mm), 必须用 Bresenham 连线否则会出条纹伪影."""
    px = dpi / 72.0
    W = max(1, int(aw * px))
    H = max(1, int(ah * px))
    buf = bytearray([255]) * (W * H)
    sx = W / aw
    sy = H / ah

    def dot(c, r):
        if 0 <= r < H and 0 <= c < W:
            buf[r * W + c] = 0

    def line(x0, y0, x1, y1):
        c = int((x0 - ax) * sx)
        r = H - 1 - int((y0 - ay) * sy)
        c1 = int((x1 - ax) * sx)
        r1 = H - 1 - int((y1 - ay) * sy)
        dc, dr = abs(c1 - c), abs(r1 - r)
        sc = 1 if c < c1 else -1
        sr = 1 if r < r1 else -1
        err = dc - dr
        while True:
            dot(c, r)
            if c == c1 and r == r1:
                break
            e2 = 2 * err
            if e2 > -dr:
                err -= dr
                c += sc
            if e2 < dc:
                err += dc
                r += sr

    K = 72.0 / 25.4          # 路径坐标是 mm, 而 ax/ay/aw/ah 是 pt, 必须先统一
    x1g, y1g = ax + aw, ay + ah
    FILLOP = ("f", "B")
    STROKEOP = ("S", "B")

    def fill(qx, qy):
        """偶奇规则扫描线填充。px 单位已是像素坐标。"""
        n = len(qx)
        if n < 3:
            return
        xs = [int(round((x - ax) * sx)) for x in qx]
        ys = [int(round(H - 1 - (y - ay) * sy)) for y in qy]
        r0 = max(0, min(ys))
        r1 = min(H - 1, max(ys))
        if r1 < r0:
            return
        for r in range(r0, r1 + 1):
            yc = r + 0.5
            xsx = []
            for i in range(n):
                y0v, y1v = ys[i], ys[(i + 1) % n]
                if y0v == y1v:
                    continue
                if (y0v <= yc < y1v) or (y1v <= yc < y0v):
                    t = (yc - y0v) / float(y1v - y0v)
                    xsx.append(xs[i] + t * (xs[(i + 1) % n] - xs[i]))
            if len(xsx) < 2:
                continue
            xsx.sort()
            for k in range(0, len(xsx) - 1, 2):
                a = int(round(xsx[k]))
                b = int(round(xsx[k + 1]))
                if b < a:
                    a, b = b, a
                if a < 0:
                    a = 0
                if b > W - 1:
                    b = W - 1
                if b >= a:
                    base = r * W
                    for c in range(a, b + 1):
                        buf[base + c] = 0

    for idx, q in enumerate(sp):
        op = ops[idx] if ops is not None and idx < len(ops) else "S"
        qx = [p[0] * K for p in q]
        qy = [p[1] * K for p in q]
        if max(qx) < ax or min(qx) > x1g:
            continue
        if max(qy) < ay or min(qy) > y1g:
            continue
        if any(ch in op for ch in FILLOP):
            fill(qx, qy)
        if any(ch in op for ch in STROKEOP):
            for i in range(len(q) - 1):
                line(qx[i], qy[i], qx[i + 1], qy[i + 1])
    return W, H, buf


if __name__ == "__main__":
    src, out = sys.argv[1], sys.argv[2]
    fx0, fy0, mmw, mmh, dpi = [float(v) for v in sys.argv[3:8]]
    sp = load(src)
    pts = [p for q in sp for p in q]
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    X0, Y1 = min(xs), max(ys)
    W, H = max(xs)-min(xs), max(ys)-min(ys)
    aw_pt = mmw*72/25.4; ah_pt = mmh*72/25.4
    ax = X0 + fx0*W; ay = Y1 - fy0*H - ah_pt
    w, h, px = render(sp, ax, ay, aw_pt, ah_pt, int(dpi))
    write_png(out, w, h, px)
    print("已输出 %s  %dx%d px @ %s DPI  (%.1f x %.1f mm)" % (out, w, h, dpi, mmw, mmh))
