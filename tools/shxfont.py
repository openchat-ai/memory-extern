"""用 ezdxf 的经过验证的 SHX 解析/渲染, 但自己定位记录起点。

ezdxf 的 load_shx_unifont_file_1_0 假设 0x1A 之后固定 6 字节再到字体名,
而这些 Autodesk "Copy" 版字体的头部布局与之差 1~2 字节, 直接调用会报
"signature byte 0x1A not found"。这里按实测布局手动定位, 之后全部交给 ezdxf。
"""
import os
import struct
from ezdxf.fonts import shapefile as SF


def _records_start(data):
    """返回 (name, above, below, mode, encoding, embed, 记录起点偏移)"""
    k = data.index(b'\x1a')
    i = k + 7                      # 0x1A 后固定 7 字节(类型/版本/两组u16) 才是字体名
    j = data.index(b'\x00', i)
    name = data[i:j].decode('latin-1', 'replace')
    above, below = data[j + 1], data[j + 2]
    mode = SF.FontMode(data[j + 3])
    enc = SF.FontEncoding(data[j + 4])
    emb = SF.FontEmbedding(data[j + 5])
    return name, above, below, mode, enc, emb, j + 7


def _parse_shapes_tolerant(data, start):
    """逐条容错解析。ezdxf 的 parse_shx_unifont_shapes 遇到一条坏记录就整体抛错,
    而这些 Autodesk "Copy" 版字体末尾常有长度异常的记录。"""
    shapes = {}
    r = SF.DataReader(data, start)
    n = len(data)
    while r.index + 4 <= n:
        try:
            num = r.u16()
            count = r.u16()
            if count == 0 or r.index >= n:
                break
            name = r.read_str()
            body = count - len(name) - 1
            if body <= 0:
                continue
            rec = r.read_bytes(body)
            shapes[num] = SF.Symbol(num, count, name,
                                   SF.parse_shape_codes(SF.DataReader(rec),
                                                        unifont=True))
        except Exception:
            break
    return shapes


def load_unifont(path):
    data = open(path, 'rb').read()
    name, above, below, mode, enc, emb, start = _records_start(data)
    sf = SF.ShapeFile(name, above=above, below=below, mode=mode,
                      encoding=enc, embed=emb)
    sf.shapes = _parse_shapes_tolerant(data, start)
    return sf


def glyph_polylines(sf, number):
    """返回 [[(x,y), ...], ...] 折线, 字体坐标系(y 向上)。取不到返回 []。"""
    try:
        p = sf.render_shape(number)
    except Exception:
        return []
    out = []
    for sp in p.sub_paths():
        try:
            pts = [(v.x, v.y) for v in sp.vertices()]
        except Exception:
            continue
        if len(pts) >= 2:
            out.append(pts)
    return out


def font_report(path):
    sf = load_unifont(path)
    ok = 0
    for k in sf.shapes:
        if glyph_polylines(sf, k):
            ok += 1
    return sf.name, sf.above, sf.below, len(sf.shapes), ok


if __name__ == '__main__':
    D = '/data/data/com.termux/files/usr/tmp/opencode/cadfont/'
    for f in ['simplex.shx', 'txt.shx', 'gbeitc.shx', 'gbenor.shx', 'romans.shx',
              'gothice.shx', 'Tssdeng1.shx', 'tssdeng.shx', 'yjkeng.shx',
              'italic.shx', 'bold.shx', 'isocp.shx', 'isocp2.shx', 'complex.shx',
              'greekc.shx', 'greeks.shx', 'dim.shx', 'greek.shx' ]:
        p = os.path.join(D, f)
        if not os.path.exists(p):
            continue
        try:
            nm, ab, bb, n, ok = font_report(p)
            print('%-14s %-26s above=%-4d below=%-3d 槽=%-4d 可渲染=%d'
                  % (f, nm[:26], ab, bb, n, ok))
        except Exception as e:
            print('%-14s 失败: %s' % (f, e))