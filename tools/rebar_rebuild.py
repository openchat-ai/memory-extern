#!/usr/bin/env python3
"""
DWG/图纸 线段聚类地基 v0.1 —— 输入 ASCII DXF, 输出:
  1) 全图线段数组 (只认 LINE, 其余实体按需)
  2) 基于距离聚类: 把散碎短线聚回"图元/字符轮廓"
  3) 聚类块分类: 长线(构件轮廓) vs 短线群(疑似文字/符号)
  → 为 [字符重建->识别桩] 提供输入

用法:
  python3 rebar_rebuild.py path.dxf [--eps 0.1] [--mincls 3]

依赖: 纯 stdlib. 若甲方文件是 DWG, 需先在 CAD '另存为' DXF (推荐 R2010 ASCII)
"""
import sys, math

def parse_dxf(path):
    """逐行读 ASCII DXF, 产出实体流. 返回 [(type, layer, pts, extra)].
    只解析 LINE / POINT / ARC / LWPOLYLINE / POLYLINE(VERTEX).
    pts: 线段列表 [(x1,y1,x2,y2), ...] 或 [(x,y),...]"""
    lines = []
    codes = []
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read().splitlines()
    # 转成 (code,value) 对
    pairs = []
    i = 0
    while i < len(text):
        c = text[i].strip()
        v = text[i+1].strip() if i+1 < len(text) else ""
        pairs.append((c, v))
        i += 2
    segs = []          # each: dict(type, layer, x1,y1,x2,y2)
    cur = None
    verts = []
    for c, v in pairs:
        c = c.strip()
        if c == "0":
            # 上一实体收尾
            if cur is not None:
                _flush(cur, verts, segs)
                cur = None
                verts = []
            # 新实体
            etype = v.strip()
            if etype in ("LINE", "ARC", "POINT", "LWPOLYLINE", "POLYLINE", "TEXT", "MTEXT"):
                cur = {"type": etype}
            continue
        if cur is None:
            continue
        if c == "8":
            cur["layer"] = v
        elif c == "6":
            cur["linetype"] = v
        elif cur["type"] == "LINE":
            if c == "10": cur["x1"] = float(v)
            elif c == "20": cur["y1"] = float(v)
            elif c == "30": cur["z1"] = float(v)
            elif c == "11": cur["x2"] = float(v)
            elif c == "21": cur["y2"] = float(v)
            elif c == "31": cur["z2"] = float(v)
        elif cur["type"] == "POINT":
            if c in ("10", "20"): cur.setdefault("px", []).append(float(v))
        elif cur["type"] == "LWPOLYLINE":
            if c == "10": cur.setdefault("pts", []).append(float(v))
            elif c == "20": cur.setdefault("pts", []).append(float(v))
        elif cur["type"] == "POLYLINE":
            pass
        elif cur["type"] == "VERTEX":
            if c == "10": verts.append(float(v))
            elif c == "20": verts.append(float(v))
        elif cur["type"] in ("TEXT", "MTEXT"):
            if c == "1" or c == "3":
                cur.setdefault("txt", v)
    if cur is not None:
        _flush(cur, verts, segs)
    return segs

def _flush(cur, verts, segs):
    t = cur["type"]
    L = cur.get("layer", "0")
    if t == "LINE":
        segs.append(("LINE", L, (cur["x1"], cur["y1"], cur["x2"], cur["y2"])))
    elif t == "ARC":
        cx, cy = cur.get("x1",0), cur.get("y1",0)
        r = cur.get("x2", 0)
        a0 = cur.get("x3", 0); a1 = cur.get("y3", 0)
        segs.append(("ARC", L, (cx, cy, r, a0, a1)))
    elif t == "POINT":
        x, y = cur["px"]
        segs.append(("POINT", L, (x, y)))
    elif t == "LWPOLYLINE":
        p = cur.get("pts", [])
        for j in range(0, len(p)-2, 2):
            segs.append(("LINE", L, (p[j], p[j+1], p[j+2], p[j+3])))
    if verts:
        for j in range(0, len(verts)-2, 2):
            segs.append(("LINE", L, (verts[j], verts[j+1], verts[j+2], verts[j+3])))

def cluster(segs, eps):
    """按端点距离聚类 (任一端点距某聚类任一线段端点 < eps 即并入).
    返回 [(代表端点集合, [(seg)], bbox)]
    稀疏图连通, 用跨散列合并. 简化: 每次并入后重算 bbox."""
    n = len(segs)
    parent = list(range(n))
    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a
    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    # 端点网格索引: (int(x/eps), int(y/eps)) -> [line_id]
    from collections import defaultdict
    bucket = defaultdict(list)
    lookups = ["p1", "p2"]
    for idx, seg in enumerate(segs):
        for key, pt in ((1, (seg[2][0], seg[2][1])), (2, (seg[2][2], seg[2][3]))):
            gx = int(pt[0] / max(eps, 1e-9)); gy = int(pt[1] / max(eps, 1e-9))
            bucket[(gx, gy)].append(idx)

    for idx, seg in enumerate(segs):
        for key, pt in ((1, (seg[2][0], seg[2][1])), (2, (seg[2][2], seg[2][3]))):
            gx, gy = int(pt[0] / eps), int(pt[1] / eps)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for j in bucket.get((gx+dx, gy+dy), []):
                        if j != idx:
                            union(idx, j)

    cl = defaultdict(list)
    for i in range(n):
        cl[find(i)].append(segs[i])
    out = []
    for root, items in cl.items():
        xs = [x for _,_,s in items for x in (s[0], s[2])]
        ys = [y for _,_,s in items for y in (s[1], s[3])]
        out.append((root, items, (min(xs), min(ys), max(xs), max(ys))))
    return out

def main():
    path = sys.argv[1] if len(sys.argv) > 1 else None
    eps = float(sys.argv[sys.argv.index("--eps")+1]) if "--eps" in sys.argv else 0.01
    mincls = int(sys.argv[sys.argv.index("--mincls")+1]) if "--mincls" in sys.argv else 3
    if not path:
        sys.exit("用法: python3 rebar_rebuild.py file.dxf [--eps 0.1] [--mincls 3]")
    segs = parse_dxf(path)
    print(f"实体线段数: {len(segs)}")
    kinds = {}
    for s in segs:
        kinds[s[0]] = kinds.get(s[0], 0) + 1
    print(f"类型分布: {kinds}")
    clusters = cluster(segs, eps)
    print(f"聚类块数: {len(clusters)}")
    # 分类: 长线块 vs 短线群
    long_, short = [], []
    for root, items, bb in clusters:
        nx = sum(1 for s in items if s[0] == "LINE")
        total_len = sum(((s[2][2]-s[2][0])**2 + (s[2][3]-s[2][1])**2)**0.5 for s in items)
        bw, bh = bb[2]-bb[0], bb[3]-bb[1]
        if bw*bh == 0:
            continue
        dens = nx / max(bw*bh, 1)
        # 文字/符号判据: 短线密集且无贯穿长线 → 短边占比高
        # (真实图纸字符 ~ 毫米级, 待用真图校准阈值)
        diag = (bw*bw + bh*bh) ** 0.5
        mean_len = total_len / max(nx, 1)
        if nx >= mincls and mean_len < diag * 0.35 and dens > 8:
            short.append((root, items, bb))
        else:
            long_.append((root, items, bb))
    print(f"疑似文字/符号短线群: {len(short)}, 构件/长线块: {len(long_)}")
    # 打印文字群样例行(前 20 个)
    for root, items, bb in short[:20]:
        nli = sum(1 for s in items if s[0] == "LINE")
        print(f"  群#{root:>4} 线数{nli:<4} bbox={bb[0]:.0f},{bb[1]:.0f} → {bb[2]:.0f},{bb[3]:.0f}  {(bb[2]-bb[0])*(bb[3]-bb[1]):.0f}px²")

if __name__ == "__main__":
    main()