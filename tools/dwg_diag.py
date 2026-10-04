#!/usr/bin/env python3
"""
图纸伪矢量图诊断器 v0.2 —— 纯 stdlib, 无第三方依赖。
读 DXF (ASCII) 文件, 统计:
  1) 实体类型分布 (LINE/ARC/TEXT/MTEXT/INSERT/POLYLINE/LWPOLYLINE/DIMENSION/HATCH...)
     → 文字是 TEXT/MTEXT 实体 还是被炸成字符轮廓(LINE/ARC+SPLINE)的关键判据
  2) 图层残留 (LAYER 表数量)
  3) 散碎程度 (LINE 实体的平均长度 → 判断是否被炸成细短线)
  4) 估计 BLOCK 引用数 (INSERT → 图块还在否)

用法:
  python3 dwg_diag.py <file.dxf> [file2.dxf ...]
DWG 文件 (二进制) 无第三方库解不开, 脚本只提示重存为 DXF (AutoCAD 菜单: 另存为 → DXF)。
"""
import os, re, sys

def sniff(path):
    with open(path, "rb") as f:
        head = f.read(16)
    if head.startswith(b"AC10") and head[:6] != b"AC101":
        return "DWG-binary(Acad R11-14)"
    if head[:6] in (b"AC1015", b"AC1018", b"AC1021", b"AC1024", b"AC1027", b"AC1032"):
        return "DWG-binary(Acad2000+)"
    if head.startswith(b"0\x00SECTION"):
        return "DXF-binary"
    if head[:2] in (b"0\r", b"0\n") or head[:1] == b"0":
        return "DXF-ASCII"
    return "unknown"

class DxfReader:
    """读 DXF ASCII 的 (code, value) 流, 只保留需要的实体块。"""
    def __init__(self, path):
        self.path = path

    def iter_pairs(self):
        code = None
        with open(self.path, "rb", errors="replace") as f:
            for line in f:
                s = line.decode("ascii", errors="ignore").rstrip("\r\n")
                if code is None:
                    try:
                        code = int(s)
                    except ValueError:
                        code = None
                    continue
                yield code, s
                code = None

    def entities(self):
        """产出 (etype, attrs_dict) 实体流: 从 0/<type> 起到下一个 0/。"""
        ent = None
        name = None
        attrs = {}
        for code, val in self.iter_pairs():
            if code == 0:
                if ent:
                    yield name, attrs
                name = val
                attrs = {}
                ent = name != "SECTION"
                if name == "ENDSEC":
                    ent = False
            elif ent and code in (8, 6, 10, 11, 12, 40, 41, 42, 50, 51, 62, 100, 1, 2, 3, 5):
                if code in (10, 11, 12):
                    attrs.setdefault(code, []).append(float(val))
                else:
                    attrs[code] = val
        if name:
            yield name, attrs

def analyze(path):
    print(f"\n===== {os.path.basename(path)} ({os.path.getsize(path)/1e6:.2f} MB)  "
          f"{sniff(path)} =====")
    if not sniff(path).startswith("DXF-ASCII"):
        print("  ! 非 ASCII DXF。若 .dwg，请用 CAD '另存为' 导出 ASCII DXF 再喂我。")
        print("    或只把带 AC10 头的 .dwg 路径发我, 我们后面专门处理. 已跳过统计。")
        return

    from collections import Counter, defaultdict
    cnt = Counter()
    layers = set()
    line_lens = []
    text_type = set()
    ins_count = 0
    nested_ins = False
    last_ell = None   # 最后一个 10/11 坐标, 估算线长

    r = DxfReader(path)
    for name, attrs in r.entities():
        if name in ("SECTION", "ENDSEC", "TABLE", "EOF"):
            continue
        cnt[name] += 1
        if name == "LAYER":
            pass
        if "8" in attrs:
            layers.add(attrs["8"])
        if name in ("TEXT", "MTEXT"):
            text_type.add(name)
            txt = attrs.get("1", attrs.get("3", ""))
            if txt:
                text_type.add("SAMPLE:" + (txt[:40] if False else str(txt)[:40]))
        if name == "INSERT":
            ins_count += 1
        if name == "LINE":
            p1 = attrs.get(10, [])
            p2 = attrs.get(11, [])
            if len(p1) >= 2 and len(p2) >= 2:
                dx = p2[0] - p1[0]; dy = p2[1] - p1[1]
                line_lens.append((dx*dx + dy*dy) ** 0.5)

    top = cnt.most_common(15)
    total_ent = sum(cnt.values())
    print(f"  实体总数: {total_ent:,}  类型数: {len(cnt)}")
    print(f"  类型 Top15: {[(k, v) for k, v in top]}")
    if total_ent:
        shares = {k: v/total_ent for k, v in cnt.items()}
        line_share = shares.get("LINE", 0)
        text_share = shares.get("TEXT", 0) + shares.get("MTEXT", 0)
        arc_share = shares.get("ARC", 0)
        print(f"  LINE 占比 {line_share:.1%} | TEXT/MTEXT 占比 {text_share:.2%} | ARC 占比 {arc_share:.1%}")
        print(f"  INSERT(图块引用) {ins_count} 个")
        if line_share > 0.5:
            print("  ⚠️ 典型伪矢量/炸开图特征: 短线占绝对主导 → 图块/实体语义全灭")
        if text_share < 0.001 and total_ent > 5000:
            print("  ⚠️ 文字实体几乎为 0 → 文字极可能也被炸成了字符轮廓(几何线), 这是最难场景")
    if line_lens:
        import statistics
        med = statistics.median(line_lens)
        mean = statistics.mean(line_lens)
        short = sum(1 for L in line_lens if L < med * 0.1)
        print(f"  LINE 数量 {len(line_lens):,} | 长度 中位 {med:.2f} 均值 {mean:.2f} "
              f"(短线<中位10%: {short})")
        if med < 2.0:
            print("  ⚠️ 中位线长<2 单位: 典型炸散细短线 (一条边线由大量短线拼成)")
    print(f"  图层数: {len(layers)}  样例: {sorted(layers)[:8]}")
    if text_type:
        print(f"  文字实体类型: {sorted(text_type)[:6]}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    for p in sys.argv[1:]:
        if os.path.exists(p):
            analyze(p)
        else:
            print(f"[skip] {p}")