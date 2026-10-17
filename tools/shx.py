"""shx.py — 自行解析 AutoCAD SHX unifont 字体。

ezdxf.fonts.shapefile 在部分文件上会抛 "pre-mature end of file" 或读不出
任何码位（实测 txt.shx / monotxt.shx / yjkeng.shx 全部失败，而 tssdeng /
gbeitc / gbenor 正常）。unifont 格式本身是公开的，这里直接按字节解析。

unifont 布局（相对文件开头）:
    0x00  变长 ASCII 头，0x1A 结束（形如 "AutoCAD-86 unifont 1.0\r\n"）
    0x1A  签名
    +1    跳过 6 字节
    +7    uint16  记录数（=1 个字体定义 + N-1 个字形）
    +9    uint16  保留
    +11   uint16  字体定义记录长度
    +13   以 0x00 结尾的字体名
    ...   above, below, mode, encoding, embed, 0x00
    然后是 N-1 条字形记录:
          uint16 shape_number
          uint16 byte_count
          uint16 data[byte_count]

字形码 data 的含义见 decode_codes()。
"""
import math
import struct

# 形状码 -> (名称, 操作数个数)
CODES = {
    0x00: ('结束', 0),
    0x01: ('降笔', 0),
    0x02: ('抬笔', 0),
    0x03: ('缩小向量长度', 1),
    0x04: ('放大向量长度', 1),
    0x05: ('压栈', 0),
    0x06: ('弹栈', 0),
    0x07: ('子形状', 1),
    0x08: ('位移', 2),
    0x09: ('多段位移', 2),
    0x0A: ('八分圆弧', 2),
    0x0B: ('分数圆弧', 5),
    0x0C: ('填充圆', 3),
    0x0D: ('顺时针填充圆弧', 5),
    0x0E: ('逆时针填充圆弧', 5),
    0x0F: ('顺时针填充椭圆', 5),
    0x10: ('逆时针填充椭圆', 5),
    0x0B + 0: ('分数圆弧', 5),
}


def _parse_codes(raw):
    """按操作数个数逐码解析。关键：终止符 0 只在"码位"上判断，
    操作数里的 0（如位移 dy=0）不是终止符。"""
    out = []
    i = 0
    n = len(raw)

    def u8():
        nonlocal i
        if i >= n:
            raise IndexError
        v = raw[i]; i += 1
        return v - 256 if v > 127 else v

    def u16():
        nonlocal i
        if i + 1 >= n:
            raise IndexError
        v = raw[i] | (raw[i + 1] << 8); i += 2
        return v - 65536 if v > 32767 else v

    while i < n:
        code = u8()
        out.append(code)
        if code == 0:
            break
        if code in (1, 2, 5, 6):
            continue
        if code in (3, 4):
            out.append(u8())
        elif code == 7:
            out.append(u16())
        elif code == 8:
            out.append(u8()); out.append(u8())
        elif code == 9:
            x = y = 1
            while (x or y) and i + 1 < n:
                x = u8(); y = u8()
                out.append(x); out.append(y)
        elif code == 10:
            out.append(u8()); out.append(u8())
        elif code == 11:
            for _ in range(4):
                out.append(u8())
            out.append(u8())
        elif code == 12:
            for _ in range(3):
                out.append(u8())
        elif code == 13:
            x = y = 1
            while (x or y) and i + 2 < n:
                x = u8(); y = u8(); b = u8()
                out += [x, y, b]
        elif code in (13, 14):
            x = y = 1
            while (x or y) and i + 2 < n:
                x = u8(); y = u8(); b = u8()
                out += [x, y, b]
        else:
            continue
    return out


def parse_unifont(data):
    """返回 {shape_number: (codes, above, below)}。"""
    i = data.index(b'\x1a') + 1
    i += 6
    n_records, _reserved, def_size = struct.unpack_from('<HHH', data, i)
    i += 6
    j = data.index(b'\x00', i)
    name = data[i:j].decode('latin-1')
    i = j + 1
    above, below = data[i], data[i + 1]
    i += 6
    shapes = {}
    while i + 4 <= len(data):
        num, nbytes = struct.unpack_from('<HH', data, i)
        i += 4
        # 记录里带一个以 \0 结尾的字形名，码数据长度要减去它
        try:
            j = data.index(b'\x00', i)
        except ValueError:
            break
        name_b = data[i:j]
        i = j + 1
        ndata = nbytes - len(name_b) - 1
        raw = data[i:i + max(ndata, 0)]
        i += max(ndata, 0)
        try:
            cs = _parse_codes(raw)
        except (IndexError, ValueError):
            continue
        shapes[num] = (cs, above, below, name_b.decode('latin-1', 'replace'))
    return shapes, name, above, below


def _octant_specs(spec):
    ccw = spec >= 0
    s = abs(spec)
    return (s >> 4) & 0xF, s & 0xF, ccw


def render(codes, above=48, below=12, vector_length=1.0):
    """形状码序列 -> [(x, y), ...] 折线点列（字体坐标系，y 向上）。"""
    out = []
    cur = []
    x = y = 0.0
    stack = []
    vl = vector_length
    i = 0
    n = len(codes)

    def emit(px, py):
        cur.append((px, py))

    while i < n:
        c = codes[i]
        i += 1
        if c in (0x00, 0x01, 0x02, 0x05, 0x06):
            if cur:
                out.append(cur)
                cur = []
            if c == 0x05:
                stack.append((x, y, vl))
            elif c == 0x06:
                if stack:
                    x, y, vl = stack.pop()
            continue
        if c == 0x03:
            vl = vl / max(codes[i], 1); i += 1; continue
        if c == 0x04:
            vl = vl * max(codes[i], 1); i += 1; continue
        if c == 0x07:
            continue
        if c == 0x08:
            dx, dy = codes[i], codes[i + 1]; i += 2
            x += dx * vl; y += dy * vl; emit(x, y); continue
        if c == 0x09:
            while i + 1 < n:
                dx, dy = codes[i], codes[i + 1]; i += 2
                if dx == 0 and dy == 0:
                    break
                x += dx * vl; y += dy * vl; emit(x, y)
            continue
        if c == 0x0A:
            radius = codes[i] * vl
            start_oct, span, ccw = _octant_specs(codes[i + 1]); i += 2
            if span == 0:
                span = 8
            a0 = math.radians(start_oct * 45)
            sweep = math.radians(span * 45)
            cx, cy = x + radius * math.cos(a0), y + radius * math.sin(a0)
            emit(cx + radius * math.cos(a0), cy + radius * math.sin(a0))
            N = max(3, span * 4)
            for k in range(1, N + 1):
                a = a0 + (sweep if ccw else -sweep) * k / N
                emit(cx + radius * math.cos(a), cy + radius * math.sin(a))
            x, y = cx + radius * math.cos(a0 + (sweep if ccw else -sweep)), \
                cy + radius * math.sin(a0 + (sweep if ccw else -sweep))
            continue
        if c == 0x0B:
            so, eo = codes[i], codes[i + 1]
            radius = ((codes[i + 2] << 8) + codes[i + 3]) * vl
            start_oct, span, ccw = _octant_specs(codes[i + 4]); i += 5
            if eo == 0:
                eo = 256
            bd = 45.0 / 256.0
            a0 = math.radians(start_oct * 45 + so * bd)
            a1 = math.radians(start_oct * 45 + eo * bd)
            if ccw:
                a1 = a0 + (a1 - a0)
            else:
                a1 = a0 - (a0 - a1)
            cx, cy = x + radius * math.cos(a0), y + radius * math.sin(a0)
            N = 16
            for k in range(N + 1):
                a = a0 + (a1 - a0) * k / N
                emit(cx + radius * math.cos(a), cy + radius * math.sin(a))
            x = cx + radius * math.cos(a1)
            y = cy + radius * math.sin(a1)
            continue
        if c in (0x0D, 0x0E):
            cx, cy = x, y
            pts = []
            while i + 2 < n:
                dx, dy, b = codes[i], codes[i + 1], codes[i + 2]; i += 3
                if dx == 0 and dy == 0:
                    break
                cx += dx * vl; cy += dy * vl
                pts.append((cx, cy, b))
            for k in range(len(pts) - 1):
                a0 = pts[k]
                a1 = pts[k + 1]
                r = (a1[2] - a0[2]) * vl
                if r <= 0:
                    emit(a1[0], a1[1])
                    continue
                # 圆心沿 (a1-a0) 方向逆时针偏转 r
                mx, my = a0[0], a0[1]
                dxv, dyv = a1[0] - a0[0], a1[1] - a0[1]
                ln = math.hypot(dxv, dyv) or 1.0
                ux, uy = dxv / ln, dyv / ln
                base = math.atan2(uy, ux)
                sweep = 2.0 * math.acos(max(-1.0, min(1.0, ln / (2 * r)))) \
                    if ln <= 2 * r else 0.0
                sgn = 1.0 if c == 0x0E else -1.0
                ccx = mx + r * math.cos(base - sgn * math.pi / 2)
                ccy = my + r * math.sin(base - sgn * math.pi / 2)
                a0a = math.atan2(my - ccy, mx - ccx)
                for q in range(9):
                    aa = a0a + sgn * sweep * q / 8.0
                    emit(ccx + r * math.cos(aa), ccy + r * math.sin(aa))
                x, y = pts[-1][0], pts[-1][1]
                emit(x, y)
            continue
        i += 1                     # 未知码，跳过
    if cur:
        out.append(cur)
    return out


def glyph(path, code):
    """取指定码位的字形点列，失败返回 None。"""
    shapes, name, above, below = parse_unifont(open(path, 'rb').read())
    # unifont 的 shape_number 通常与码位一一对应；找不到就按顺序回退
    key = code if code in shapes else None
    if key is None:
        return None
    return render(shapes[key][0], above, below), name
