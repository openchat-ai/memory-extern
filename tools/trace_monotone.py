import os
import struct
from collections import defaultdict, Counter

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
raw = open(os.path.join(repo, "data", "expert_trace.bin"), "rb").read()
n = len(raw) // 4
tr = struct.unpack('<%di' % n, raw)
keys = [(tr[i] << 20) | tr[i + 1] for i in range(0, n - 1, 2)]

# 按层分组成 runs, pass 定义为层切换间的连续段
runs = []
cur, curlay = [], None
for k in keys:
    lay = k >> 20
    if curlay != lay:
        if cur:
            runs.append((curlay, cur))
        cur, curlay = [], lay
    cur.append(k)
if cur:
    runs.append((curlay, cur))

# pass = 同一层的连续请求块（每块=一遍装载）。按 (layer) 分组, 每个 run 是一个 pass 对?
# 笔记说 8 遍单调超集: 每层每个 pass 是离散的 (连续同层请求=一遍)
passes = [e for _, e in runs]
print(f"总请求={len(keys)}  runs(连续同层块)={len(passes)}")
from collections import Counter as C
lay_cnt = C(lay for lay, _ in runs)
print(f"每层 pass 次数分布: {dict(C(lay_cnt.values()))}")

# 取出现最多的层(比如层0?), 显示其 pass 数及单调超集
# 看 runs 里每层的 pass 块数
by_layer_pass = defaultdict(list)
for lay, e in runs:
    by_layer_pass[lay].append(set(e))
print(f"\n出现层数: {len(by_layer_pass)}")
# 单调超集: pass_i 是否 ⊆ pass_{i+1} (严格: 后一遍包含前一遍全部)
viol = []
per_layer = {}
for lay, ps in by_layer_pass.items():
    ok = True
    for i in range(len(ps) - 1):
        if not ps[i] <= ps[i + 1]:
            ok = False
    per_layer[lay] = (len(ps), ok)
    if not ok:
        viol.append(lay)
print(f"\n单调超集 pass_i⊆pass_i+1 成立层数: {len(by_layer_pass)-len(viol)}/{len(by_layer_pass)}")
if viol:
    print(f"违反层(前12): {viol[:12]}")
else:
    print("全部层单调超集成立 ✓")

# 每 pass 冷启动率: pass_v 中未在前 pass 出现过的专家比例 (=新增率)
# 若单调超集成立, pass宽度每次固定增长
print("\n=== 每 pass 新增专家率(前 5 层示意, 单调超集 => 只增不减) ===")
for lay in sorted(by_layer_pass)[:5]:
    ps = by_layer_pass[lay]
    cum = set()
    print(f"L{lay}: pass数={len(ps)}")
    prev_n = None
    for v, p in enumerate(ps):
        new = len(p - cum)
        hit_vs_cum = len(p & cum) / len(p) if v > 0 else 0.0
        print(f"  pass{v}: unique={len(p):>5} 新增={new:>5} 相对前pass累计命中={hit_vs_cum:6.2%}")
        cum |= p