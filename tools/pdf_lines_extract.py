#!/usr/bin/env python3
"""
pdf_lines_extract v0.1 —— 判定 PDF 是否为矢量源，并提取线段坐标。

用法:
  python3 pdf_lines_extract.py 某图纸.pdf [输出.txt]

行为:
  1. 逐页统计矢量绘图指令: 直线/曲线/矩形/文本
  2. 若是矢量源(线数>0) → 把所有直线段导出为 "x1 y1 x2 y2" 文本
     (默认输出到 <pdf名>.segs.txt, 或指定第二参数)
  3. 同时报告页内是否含真文字层 (get_text 是否非空) —— 有则连 OCR 都省了

依赖: pip install pymupdf
"""
import sys, os


def analyze(path, outpath=None):
    try:
        import fitz  # pymupdf
    except ImportError:
        sys.exit("未装 pymupdf，请先: pip install pymupdf")
    doc = fitz.open(path)
    print(f"PDF: {os.path.basename(path)}  页数={len(doc)}")
    total_lines = 0
    total_curves = 0
    total_re = 0
    out_segs = []
    for pno, page in enumerate(doc):
        drawings = page.get_drawings()
        text = page.get_text().strip()
        n_l = n_c = n_r = 0
        psegs = []
        for dr in drawings:
            for item in dr["items"]:
                op = item[0]
                if op == "l":            # 直线 (x0,y0,x1,y1)
                    x0, y0, x1, y1 = item[1], item[2], item[3], item[4]
                    if (x0, y0) != (x1, y1):
                        n_l += 1
                        out_segs.append((x0, y0, x1, y1))
                elif op == "re":         # 矩形
                    x0, y0, x1, y1 = item[1], item[2], item[3], item[4]
                    n_r += 1
                    psegs += [(x0, y0, x1, y0), (x1, y0, x1, y1),
                              (x1, y1, x0, y1), (x0, y1, x0, y0)]
                elif op == "c" or op == "c1":   # 贝塞尔曲线
                    n_c += 1
        if psegs:
            out_segs.extend(psegs)
        total_lines += n_l
        total_curves += n_c
        total_re += n_r
        print(f"  页{pno+1}: 直线{n_l:>6} 曲线{n_c:>5} 矩形{n_r:>4} "
              f"文字层字符数={len(text):>7} {'有真文字!' if text else '无'}")
    print(f"\n合计: 直线 {total_lines}, 曲线 {total_curves}, 矩形 {total_re}")
    if total_lines + total_re == 0:
        print("\n结论: 该 PDF 无矢量线 → 可能是扫描/位图件。")
        print("      (若是位图则此路不通，只能走渲染+识别；或问原 CAD 要一份 DXF/原始 PDF)")
        return
    if outpath is None:
        outpath = os.path.splitext(path)[0] + ".segs.txt"
    with open(outpath, "w", encoding="utf-8") as f:
        for x0, y0, x1, y1 in out_segs:
            f.write(f"{x0:.4f} {y0:.4f} {x1:.4f} {y1:.4f}\n")
    print(f"\n结论: 矢量源确认! 已导出 {len(out_segs)} 条线段 → {outpath}")
    print("这些坐标可以直接喂给我们的缝合器 tools/rebar_stitch.py 做几何重建。")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    p = sys.argv[1]
    o = sys.argv[2] if len(sys.argv) > 2 else None
    analyze(p, o)