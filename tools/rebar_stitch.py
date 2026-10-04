#!/usr/bin/env python3
"""
rebar_stitch v0.2 —— 噪声线段缝合器: 图像识别产物 → 结构重建

输入: 文本, 每行一条线段 "x1 y1 x2 y2 [score]"
      (像素坐标, 容忍噪声: 断笔/毛边/错位/同线多段)
流程: 空间聚类 → 簇内端点连续缝合(链) → RDP简化 → 分类(字符/轮廓)
用法:
  python3 rebar_stitch.py lines.txt [--eps 12] [--link 8] [--min 3]
  python3 rebar_stitch.py --test
纯 stdlib. 手机/电脑皆可跑.
"""
import sys, math, random
from collections import defaultdict

# ---------- 输入 ----------
def load_txt(path):
    segs = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln, line in enumerate(f, 1):
            p = line.split()
            if len(p) < 4:
                continue
            try:
                x1, y1, x2, y2 = map(float, p[:4])
            except ValueError:
                continue
            if (x1, y1) == (x2, y2):
                continue
            s = 1.0
            if len(p) >= 5:
                try:
                    s = float(p[4])
                except ValueError:
                    pass
            segs.append((x1, y1, x2, y2, s, ln))
    return segs

# ---------- 空间聚类: 端点入桶 + 并查集 (端点间距<eps 才相连) ----------
def cluster(segs, eps):
    n = len(segs)
    if n == 0:
        return []
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
    buckets = defaultdict(list)
    for i, s in enumerate(segs):
        for pt in ((s[0], s[1]), (s[2], s[3])):
            buckets[(int(pt[0] / eps), int(pt[1] / eps))].append((i, pt))
    def check_cell(bx, by, i, px, py, touched):
        for j, (ex, ey) in buckets.get((bx, by), ()):
            if j == i:
                continue
            if (px - ex) ** 2 + (py - ey) ** 2 < eps * eps:
                union(i, j)
                touched.add(j)
    for i, s in enumerate(segs):
        for pt in ((s[0], s[1]), (s[2], s[3])):
            gx, gy = int(pt[0] / eps), int(pt[1] / eps)
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    check_cell(gx + dx, gy + dy, i, pt[0], pt[1], set())
    out = defaultdict(list)
    for i in range(n):
        out[find(i)].append(i)
    return list(out.values())

# ---------- 簇内缝合: 沿端点连续性贪心生长成链 ----------
def grow_chain(start, open_segs, segs, tol):
    s = segs[start]
    pts = [(s[0], s[1]), (s[2], s[3])]
    for direction in (0, 1):
        while True:
            px, py = pts[0] if direction == 0 else pts[-1]
            best, bd, bi = None, tol, None
            for i in open_segs:
                t = segs[i]
                for e in ((t[0], t[1]), (t[2], t[3])):
                    d = math.hypot(px - e[0], py - e[1])
                    if d < bd:
                        best, bd, bi = e, d, i
            if best is None:
                break
            open_segs.discard(bi)
            if direction == 0:
                pts.insert(0, best)
            else:
                pts.append(best)
    return pts

def stitch_cluster(idxs, segs, tol):
    open_segs = set(idxs)
    chains = []
    while open_segs:
        start = min(open_segs)
        open_segs.discard(start)
        pts = grow_chain(start, open_segs, segs, tol)
        if len(pts) >= 2:
            chains.append(pts)
    return chains

# ---------- RDP 简化 ----------
def simplify_chain(pts, eps=2.0):
    if len(pts) <= 2:
        return pts
    def perp(a, b, p):
        L2 = (b[0]-a[0])**2 + (b[1]-a[1])**2
        if L2 == 0:
            return math.hypot(p[0]-a[0], p[1]-a[1])
        return abs((b[0]-a[0])*(a[1]-p[1]) - (a[0]-p[0])*(b[1]-a[1])) / math.sqrt(L2)
    out = [pts[0]]
    i = 0
    while i < len(pts) - 1:
        j = i + 1
        while j < len(pts) - 1 and perp(pts[i], pts[j+1], pts[j]) < eps:
            j += 1
        out.append(pts[j])
        i = j
    return out

# ---------- 簇特征 ----------
def cluster_stats(idxs, segs, chains):
    xs = [segs[i][c] for i in idxs for c in (0, 2)]
    ys = [segs[i][c] for i in idxs for c in (1, 3)]
    bb = (min(xs), min(ys), max(xs), max(ys))
    w, h = bb[2]-bb[0], bb[3]-bb[1]
    total_vtx = sum(len(c) for c in chains)
    max_chain = max((len(c) for c in chains), default=0)
    return bb, w, h, total_vtx, max_chain

# ---------- 主流程 ----------
def analyze(segs, eps, link_tol, min_seg):
    out = []
    for k, idxs in enumerate(cluster(segs, eps)):
        if len(idxs) < min_seg:
            continue
        chains = stitch_cluster(idxs, segs, link_tol)
        chains = [simplify_chain(c) for c in chains]
        bb, w, h, total_vtx, max_chain = cluster_stats(idxs, segs, chains)
        n_chains = len(chains)
        # 分类启发: 字符=短链多/无长连; 轮廓=少链长跨
        aspect = max(w, 1e-6) / max(h, 1e-6)
        if max_chain * 0.5 < min(w, h) and n_chains >= 4:
            cls = "疑似字符/密集短线"
        else:
            cls = "轮廓/长链"
        out.append((k, len(idxs), n_chains, total_vtx, bb, cls))
    return out

# ---------- 合成噪声测试 ----------
def make_noise_synth(noise=1.0, frag=6, seed=7):
    random.seed(seed)
    segs = []
    # 方框
    box = [(0,0,30,0),(30,0,30,40),(30,40,0,40),(0,40,0,0)]
    for x1,y1,x2,y2 in box:
        L = math.hypot(x2-x1, y2-y1)
        n = max(2, int(L/frag))
        for i in range(n):
            t0 = i/n; t1 = (i+1)/n
            a = (x1+(x2-x1)*t0 + random.uniform(-noise,noise),
                 y1+(y2-y1)*t0 + random.uniform(-noise,noise))
            b = (x1+(x2-x1)*t1 + random.uniform(-noise,noise),
                 y1+(y2-y1)*t1 + random.uniform(-noise,noise))
            segs.append((round(a[0],1), round(a[1],1), round(b[0],1), round(b[1],1), 1.0, 0))
    # 数字 8: 两个椭圆
    for cy in (12, 32):
        for i in range(18):
            a0 = 2*math.pi*i/18; a1 = 2*math.pi*(i+1)/18
            xA = 60+10*math.cos(a0) + random.uniform(-noise,noise)
            yA = cy+10*math.sin(a0) + random.uniform(-noise,noise)
            xB = 60+10*math.cos(a1) + random.uniform(-noise,noise)
            yB = cy+10*math.sin(a1) + random.uniform(-noise,noise)
            segs.append((round(xA,1), round(yA,1), round(xB,1), round(yB,1), 1.0, 0))
    return segs

def main():
    args = sys.argv[1:]
    if "--test" in args:
        segs = make_noise_synth()
        print(f"合成噪声线段: {len(segs)} 条 (图像识别模拟)")
        rep = analyze(segs, eps=10, link_tol=6, min_seg=3)
        print(f"聚类簇(>=3线): {len(rep)}")
        for k, n, nc, tv, bb, cls in rep:
            print(f"  簇#{k:<3} 线数{n:<3} 链数{nc} 顶点{tv}  bbox=({bb[0]:.0f},{bb[1]:.0f})-({bb[2]:.0f},{bb[3]:.0f})  {cls}")
        print("期望: 方框(0-30,0-40) 和 8字(50-70,2-42) 各成一簇")
        return
    if not args:
        sys.exit(__doc__)
    path = args[0]
    eps, link_tol, min_seg = 12, 8, 3
    if "--eps" in args: eps = float(args[args.index("--eps")+1])
    if "--link" in args: link_tol = float(args[args.index("--link")+1])
    if "--min" in args: min_seg = int(args[args.index("--min")+1])
    segs = load_txt(path)
    print(f"输入线段: {len(segs)}")
    rep = analyze(segs, eps, link_tol, min_seg)
    print(f"聚类簇(>=min): {len(rep)}")
    for k, n, nc, tv, bb, cls in rep:
        print(f"  簇#{k:<3} 线数{n:<4} 链数{nc} 顶点{tv}  bbox=({bb[0]:.0f},{bb[1]:.0f})-({bb[2]:.0f},{bb[3]:.0f})  {cls}")

if __name__ == "__main__":
    main()